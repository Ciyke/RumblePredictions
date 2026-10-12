// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PredictionMarket
 * @notice Parimutuel betting on matchroom outcomes, for Avalanche C-Chain.
 *
 * ─── How it differs from TestMarket ───────────────────────────────────────────
 *
 *  TestMarket (Arc Testnet) was a plumbing test: `predict` recorded a choice but
 *  escrowed nothing, and every depositor could withdraw in full at any time
 *  regardless of outcome. It could not pay a winner and generated no revenue.
 *  This contract escrows on bet, pays winners from the losing pool, and takes a
 *  rake. It is intended to hold real money.
 *
 * ─── Parimutuel model ─────────────────────────────────────────────────────────
 *
 *  Two sides per market. Bettors stake into their side's pool. At resolution the
 *  losing pool, minus rake, is distributed across the winning pool pro rata:
 *
 *      rake    = losingPool * rakeBps / 10_000
 *      payout  = stake + stake * (losingPool - rake) / winningPool
 *
 *  Rake is charged only on winnings, never on principal — a winner always gets
 *  at least their stake back. There is no house position and no price risk to
 *  the protocol: payouts are funded entirely by the losing side.
 *
 * ─── Resolution, before the oracle exists ─────────────────────────────────────
 *
 *  Matchroom outcomes are off-chain and no oracle has been built yet, so
 *  `resolver` is a plain address that reports the winner. It is swappable by the
 *  owner, so the real oracle can be dropped in later without redeploying or
 *  migrating open liquidity.
 *
 *  That address is trusted, which is why every market carries a
 *  `resolveDeadline`. If it passes without a resolution, ANYONE may call
 *  `enableRefunds` and every bettor withdraws their full stake. A market can
 *  therefore never strand user funds waiting on a resolver that has gone away,
 *  which is the failure mode that matters most while resolution is centralised.
 *
 * ─── Settlement token ─────────────────────────────────────────────────────────
 *
 *  Set per market. address(0) settles in native AVAX; any other address is an
 *  ERC-20 (e.g. native USDC on C-Chain). Fee-on-transfer and rebasing tokens are
 *  NOT supported — pools are credited with the balance delta actually received,
 *  but rebasing would still desynchronise accounting after the fact.
 */
contract PredictionMarket is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────

    uint8  public constant TEAM_A       = 0;
    uint8  public constant TEAM_B       = 1;
    uint16 public constant BPS_DENOM    = 10_000;
    /// @notice Hard ceiling on rake. The owner cannot exceed this, ever.
    uint16 public constant MAX_RAKE_BPS = 1_000; // 10%

    // ─── Types ────────────────────────────────────────────────────────────────

    enum Status {
        Open,      // accepting bets until closesAt, awaiting resolution
        Resolved,  // winner set, winners may claim
        Refunding  // no valid resolution; everyone reclaims their stake
    }

    struct Market {
        address token;           // address(0) = native AVAX
        uint64  closesAt;        // bets rejected at/after this timestamp
        uint64  resolveDeadline; // after this, refunds can be forced by anyone
        uint16  rakeBps;         // snapshotted at creation, immune to later changes
        Status  status;
        uint8   winner;          // meaningful only when status == Resolved
        uint256 poolA;
        uint256 poolB;
        uint256 rakeAmount;      // computed at resolution
        bool    rakeWithdrawn;
    }

    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice Number of markets ever created. Ids run 1..marketCount, so the UI
    ///         can enumerate every market without an indexer.
    uint256 public marketCount;

    mapping(uint256 => Market) public markets;

    /// @dev marketId => bettor => [stakeOnA, stakeOnB]
    mapping(uint256 => mapping(address => uint256[2])) private _stakes;

    /// @dev marketId => bettor => already claimed/refunded
    mapping(uint256 => mapping(address => bool)) public claimed;

    /// @notice May resolve markets. Swap for the real oracle when it ships.
    address public resolver;

    /// @notice Receives rake. Should not be the deployer key.
    address public treasury;

    /// @notice Rake applied to newly created markets, in basis points.
    uint16 public rakeBps;

    // ─── Events ───────────────────────────────────────────────────────────────

    event MarketCreated(
        uint256 indexed marketId,
        address indexed token,
        uint64          closesAt,
        uint64          resolveDeadline,
        uint16          rakeBps
    );
    event BetPlaced(uint256 indexed marketId, address indexed bettor, uint8 indexed side, uint256 amount);
    event MarketResolved(uint256 indexed marketId, uint8 indexed winner, uint256 rakeAmount);
    event RefundsEnabled(uint256 indexed marketId, string reason);
    event Claimed(uint256 indexed marketId, address indexed bettor, uint256 amount);
    event Refunded(uint256 indexed marketId, address indexed bettor, uint256 amount);
    event RakeWithdrawn(uint256 indexed marketId, address indexed to, uint256 amount);
    event ResolverUpdated(address indexed resolver);
    event TreasuryUpdated(address indexed treasury);
    event RakeBpsUpdated(uint16 rakeBps);

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address _resolver, address _treasury, uint16 _rakeBps) Ownable() {
        require(_resolver != address(0), "PM: zero resolver");
        require(_treasury != address(0), "PM: zero treasury");
        require(_rakeBps <= MAX_RAKE_BPS, "PM: rake exceeds max");

        resolver = _resolver;
        treasury = _treasury;
        rakeBps  = _rakeBps;

        emit ResolverUpdated(_resolver);
        emit TreasuryUpdated(_treasury);
        emit RakeBpsUpdated(_rakeBps);
    }

    modifier onlyResolver() {
        require(msg.sender == resolver, "PM: not resolver");
        _;
    }

    // ─── Market creation ──────────────────────────────────────────────────────

    /**
     * @notice Open a new market.
     * @param token           address(0) for native AVAX, else an ERC-20
     * @param closesAt        timestamp bets stop being accepted
     * @param resolveDeadline timestamp after which refunds can be forced
     *
     * @dev The rake is snapshotted here. Changing `rakeBps` later cannot alter
     *      the terms of a market people have already bet into.
     */
    function createMarket(
        address token,
        uint64  closesAt,
        uint64  resolveDeadline
    ) external returns (uint256 marketId) {
        require(msg.sender == owner() || msg.sender == resolver, "PM: not authorised");
        require(closesAt > block.timestamp,     "PM: closesAt in the past");
        require(resolveDeadline > closesAt,     "PM: deadline must follow close");

        marketId = ++marketCount;

        Market storage m = markets[marketId];
        m.token           = token;
        m.closesAt        = closesAt;
        m.resolveDeadline = resolveDeadline;
        m.rakeBps         = rakeBps;
        m.status          = Status.Open;

        emit MarketCreated(marketId, token, closesAt, resolveDeadline, rakeBps);
    }

    // ─── Betting ──────────────────────────────────────────────────────────────

    /**
     * @notice Stake on a side. Funds are escrowed until resolution or refund.
     * @param amount ignored for native markets, where msg.value is the stake
     *
     * @dev Betting both sides is allowed; it is a self-hedge that only loses the
     *      rake, so there is no reason to forbid it.
     */
    function bet(uint256 marketId, uint8 side, uint256 amount)
        external
        payable
        nonReentrant
    {
        Market storage m = markets[marketId];
        require(m.closesAt != 0,                "PM: no such market");
        require(m.status == Status.Open,        "PM: market not open");
        require(block.timestamp < m.closesAt,   "PM: betting closed");
        require(side == TEAM_A || side == TEAM_B, "PM: invalid side");

        uint256 staked = _pullFunds(m.token, amount);
        require(staked > 0, "PM: zero stake");

        if (side == TEAM_A) {
            m.poolA += staked;
        } else {
            m.poolB += staked;
        }
        _stakes[marketId][msg.sender][side] += staked;

        emit BetPlaced(marketId, msg.sender, side, staked);
    }

    // ─── Resolution ───────────────────────────────────────────────────────────

    /**
     * @notice Report the winning side.
     *
     * @dev If the winning pool is empty there is nobody to pay the losing pool
     *      to, so the market falls back to refunds rather than trapping funds or
     *      handing the entire pot to the treasury.
     */
    function resolve(uint256 marketId, uint8 winner) external onlyResolver {
        Market storage m = markets[marketId];
        require(m.closesAt != 0,                    "PM: no such market");
        require(m.status == Status.Open,            "PM: already settled");
        require(block.timestamp >= m.closesAt,      "PM: betting still open");
        require(block.timestamp <= m.resolveDeadline, "PM: past resolve deadline");
        require(winner == TEAM_A || winner == TEAM_B, "PM: invalid winner");

        uint256 winPool  = winner == TEAM_A ? m.poolA : m.poolB;
        uint256 losePool = winner == TEAM_A ? m.poolB : m.poolA;

        if (winPool == 0) {
            m.status = Status.Refunding;
            emit RefundsEnabled(marketId, "no stake on winning side");
            return;
        }

        uint256 rake = (losePool * m.rakeBps) / BPS_DENOM;

        m.status     = Status.Resolved;
        m.winner     = winner;
        m.rakeAmount = rake;

        emit MarketResolved(marketId, winner, rake);
    }

    /**
     * @notice Force a market into refund mode once its deadline has passed
     *         without resolution. Callable by anyone — deliberately permissionless,
     *         so bettors are never dependent on the operator to recover funds.
     */
    function enableRefunds(uint256 marketId) external {
        Market storage m = markets[marketId];
        require(m.closesAt != 0,             "PM: no such market");
        require(m.status == Status.Open,     "PM: already settled");
        require(block.timestamp > m.resolveDeadline, "PM: deadline not reached");

        m.status = Status.Refunding;
        emit RefundsEnabled(marketId, "resolve deadline passed");
    }

    /// @notice Cancel an unresolved market early and refund everyone.
    function cancelMarket(uint256 marketId) external onlyOwner {
        Market storage m = markets[marketId];
        require(m.closesAt != 0,         "PM: no such market");
        require(m.status == Status.Open, "PM: already settled");

        m.status = Status.Refunding;
        emit RefundsEnabled(marketId, "cancelled by owner");
    }

    // ─── Claiming ─────────────────────────────────────────────────────────────

    /**
     * @notice Collect winnings from a resolved market, or reclaim stake from a
     *         refunding one. One call settles a bettor's entire position.
     */
    function claim(uint256 marketId) external nonReentrant returns (uint256 amount) {
        Market storage m = markets[marketId];
        require(m.closesAt != 0,         "PM: no such market");
        require(m.status != Status.Open, "PM: not settled yet");
        require(!claimed[marketId][msg.sender], "PM: already claimed");

        bool refunding = m.status == Status.Refunding;
        amount = refunding
            ? _refundAmount(marketId, msg.sender)
            : _payoutAmount(marketId, msg.sender);

        require(amount > 0, "PM: nothing to claim");

        // Effects before interaction.
        claimed[marketId][msg.sender] = true;

        _sendFunds(m.token, msg.sender, amount);

        if (refunding) {
            emit Refunded(marketId, msg.sender, amount);
        } else {
            emit Claimed(marketId, msg.sender, amount);
        }
    }

    /// @notice Send a resolved market's rake to the treasury. Callable by anyone.
    function withdrawRake(uint256 marketId) external nonReentrant {
        Market storage m = markets[marketId];
        require(m.status == Status.Resolved, "PM: not resolved");
        require(!m.rakeWithdrawn,            "PM: rake already withdrawn");
        require(m.rakeAmount > 0,            "PM: no rake");

        m.rakeWithdrawn = true;
        _sendFunds(m.token, treasury, m.rakeAmount);

        emit RakeWithdrawn(marketId, treasury, m.rakeAmount);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    /// @notice A bettor's stake on each side.
    function stakesOf(uint256 marketId, address bettor)
        external
        view
        returns (uint256 onA, uint256 onB)
    {
        onA = _stakes[marketId][bettor][TEAM_A];
        onB = _stakes[marketId][bettor][TEAM_B];
    }

    /**
     * @notice What `bettor` would receive right now. Returns 0 while a market is
     *         still Open, since nothing is owed until it settles.
     */
    function previewClaim(uint256 marketId, address bettor) external view returns (uint256) {
        Market storage m = markets[marketId];
        if (m.status == Status.Open || claimed[marketId][bettor]) return 0;
        return m.status == Status.Refunding
            ? _refundAmount(marketId, bettor)
            : _payoutAmount(marketId, bettor);
    }

    /**
     * @notice Live odds as a multiplier on a winning stake, scaled by 1e18.
     *         1e18 means break-even. Reverts nothing — returns 0 for an empty side.
     * @dev Indicative only: the ratio moves with every subsequent bet.
     */
    function impliedPayoutRatio(uint256 marketId, uint8 side) external view returns (uint256) {
        Market storage m = markets[marketId];
        uint256 winPool  = side == TEAM_A ? m.poolA : m.poolB;
        uint256 losePool = side == TEAM_A ? m.poolB : m.poolA;
        if (winPool == 0) return 0;

        uint256 rake = (losePool * m.rakeBps) / BPS_DENOM;
        return 1e18 + ((losePool - rake) * 1e18) / winPool;
    }

    function totalPool(uint256 marketId) external view returns (uint256) {
        return markets[marketId].poolA + markets[marketId].poolB;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /// @notice Point resolution at a new address — the real oracle, once built.
    function setResolver(address _resolver) external onlyOwner {
        require(_resolver != address(0), "PM: zero resolver");
        resolver = _resolver;
        emit ResolverUpdated(_resolver);
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "PM: zero treasury");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    /// @dev Applies to future markets only; existing ones keep their snapshot.
    function setRakeBps(uint16 _rakeBps) external onlyOwner {
        require(_rakeBps <= MAX_RAKE_BPS, "PM: rake exceeds max");
        rakeBps = _rakeBps;
        emit RakeBpsUpdated(_rakeBps);
    }

    // ─── Internals ────────────────────────────────────────────────────────────

    function _payoutAmount(uint256 marketId, address bettor) private view returns (uint256) {
        Market storage m = markets[marketId];
        uint256 stake = _stakes[marketId][bettor][m.winner];
        if (stake == 0) return 0;

        uint256 winPool  = m.winner == TEAM_A ? m.poolA : m.poolB;
        uint256 losePool = m.winner == TEAM_A ? m.poolB : m.poolA;
        uint256 profit   = losePool - m.rakeAmount;

        // Stake back, plus a pro-rata share of what the losing side forfeited.
        return stake + (stake * profit) / winPool;
    }

    function _refundAmount(uint256 marketId, address bettor) private view returns (uint256) {
        return _stakes[marketId][bettor][TEAM_A] + _stakes[marketId][bettor][TEAM_B];
    }

    /**
     * @dev Credits the balance actually received rather than the amount asked
     *      for, so a token that transfers less than requested cannot inflate a
     *      pool beyond what this contract holds.
     */
    function _pullFunds(address token, uint256 amount) private returns (uint256 received) {
        if (token == address(0)) {
            require(msg.value > 0, "PM: no AVAX sent");
            return msg.value;
        }

        require(msg.value == 0, "PM: AVAX sent to ERC20 market");
        require(amount > 0,     "PM: zero amount");

        IERC20 erc20 = IERC20(token);
        uint256 before = erc20.balanceOf(address(this));
        erc20.safeTransferFrom(msg.sender, address(this), amount);
        received = erc20.balanceOf(address(this)) - before;
    }

    function _sendFunds(address token, address to, uint256 amount) private {
        if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "PM: AVAX transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
