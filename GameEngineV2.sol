// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./IngredientNFT.sol";
import "./PotionNFT.sol";

/**
 * @title GameEngineV2
 * @notice Rumble Ingredient Hunt for Avalanche C-Chain.
 *
 * ─── What changed from V1 (Somnia) ────────────────────────────────────────────
 *
 *  1. NO SESSION KEYS. V1 approved an ephemeral keypair for 24h and forwarded
 *     native gas to it so 51 of the 52 daily transactions could be signed
 *     silently. That is gone: every call must come from the player's own wallet
 *     and is signed manually. Consequently the contract never holds, forwards,
 *     or spends native value — `beginHunt` is no longer payable, and the
 *     operator no longer subsidises anyone's gas.
 *
 *  2. UNLIMITED RUNS PER DAY. V1 keyed all progress on the season day and
 *     enforced one hunt and one potion per day. State is now keyed on an
 *     ever-incrementing per-player run id, so a player may complete the full
 *     25-box cycle and craft a potion as many times per day as they are willing
 *     to pay gas for. Potion supply is intentionally uncapped.
 *
 *  3. RUN-SEEDED BOX LAYOUT. V1 seeded the shuffle with
 *     keccak256(day, player, chainId), which is constant for a player within a
 *     day — with repeat runs allowed that would deal an identical board every
 *     single time. The run id is now part of the seed so each run differs.
 *
 *  4. NO BACKEND. V1 emitted events for an off-chain listener to credit points
 *     and serve a leaderboard. There is no leaderboard and no indexer; every
 *     figure the UI shows is read directly from this contract.
 *
 *  5. CONFIGURABLE SEASON. V1 hardcoded Somnia's March-May 2026 window as
 *     constants, which have since expired. The start is now a constructor
 *     argument and the season runs SEASON_DAYS from it.
 *
 * ─── Flow (52 manual signatures per run) ──────────────────────────────────────
 *
 *   1.  beginHunt()          — burns any leftover ingredients, opens a new run
 *   2.  openBox(0)           — mints one ingredient
 *   3.  closeBox(0)
 *       ... boxes 1-24 ...
 *  52.  createPotion()       — burns the 4 useful + all junk, mints a Potion NFT
 *
 * ─── Box distribution per run (pseudo-random, recipe always possible) ─────────
 *
 *    4 useful : exactly 1x Water, 1x Crystalix, 1x Sunfiber, 1x Coppervein
 *   21 junk   : 11x Stone, 10x Poison
 *   All 25 Fisher-Yates shuffled with seed = keccak256(day, player, chainId, runId)
 *
 *   NOTE: pseudo-random and predictable off-chain. A player can simulate a run
 *   before submitting it. Since runs are unlimited and every board contains a
 *   complete recipe by construction, there is nothing to gain by grinding — the
 *   outcome of a completed run is always one potion. Upgrade to VRF only if
 *   scoring is ever made outcome-dependent.
 *
 * ─── Points ───────────────────────────────────────────────────────────────────
 *   A flat 50 per potion. There is no voucher and no multiplier: with the
 *   leaderboard removed nothing ranks or spends points, so they are an uncapped
 *   personal tally kept for display only.
 */
contract GameEngineV2 is Ownable, ReentrancyGuard {

    // ─── External Contracts ───────────────────────────────────────────────────
    IngredientNFT public ingredientNFT;
    PotionNFT     public potionNFT;

    // ─── Season ───────────────────────────────────────────────────────────────
    /// @notice Unix timestamp the season opens at. Set once at deploy.
    uint256 public immutable SEASON_START;
    /// @notice Season length in days.
    uint256 public constant SEASON_DAYS = 64;
    /// @notice Extra window after the last day so an in-progress run can finish.
    uint256 public constant GRACE_PERIOD = 48 hours;

    // ─── Ingredient Token IDs ─────────────────────────────────────────────────
    uint256 public constant WATER      = 1;
    uint256 public constant CRYSTALIX  = 2;
    uint256 public constant SUNFIBER   = 3;
    uint256 public constant COPPERVEIN = 4;
    uint256 public constant STONE      = 5;
    uint256 public constant POISON     = 6;

    // ─── Game Constants ───────────────────────────────────────────────────────
    uint256 public constant BOXES_PER_RUN     = 25;
    uint256 public constant POINTS_PER_POTION = 50;

    /// @dev All 25 box bits set: (1 << 25) - 1
    uint32 public constant ALL_BOXES = 33554431;

    // ─── Per-Run State ────────────────────────────────────────────────────────
    struct RunState {
        uint32 opened;         // bitmask: bit i = box i opened
        uint32 closed;         // bitmask: bit i = box i closed
        bool   begun;
        bool   potionCrafted;
        uint64 day;            // season day the run was opened on
    }

    /// @notice Latest run id per player. 0 means the player has never begun a run.
    mapping(address => uint256) public currentRun;

    /// @notice player => runId => state
    mapping(address => mapping(uint256 => RunState)) public runState;

    // ─── Season Tallies ───────────────────────────────────────────────────────
    mapping(address => uint256) public totalSeasonPoints;
    mapping(address => uint256) public potionsCrafted;

    // ─── Events ───────────────────────────────────────────────────────────────
    event HuntBegun(address indexed player, uint256 indexed runId, uint256 day);
    event BoxOpened(
        address indexed player,
        uint256 indexed runId,
        uint8   indexed boxIndex,
        uint8           resourceType
    );
    event BoxClosed(address indexed player, uint256 indexed runId, uint8 indexed boxIndex);
    event PotionCrafted(
        address indexed player,
        uint256 indexed runId,
        uint256         points,
        uint256         tokenId
    );
    event IngredientNFTUpdated(address indexed ingredientNFT);
    event PotionNFTUpdated(address indexed potionNFT);

    // ─── Constructor ──────────────────────────────────────────────────────────
    /**
     * @param _ingredientNFT ERC-1155 ingredients; this contract must be its gameEngine
     * @param _potionNFT     ERC-721 potions; this contract must be its gameEngine
     * @param _seasonStart   unix timestamp the season opens; 0 means "now"
     */
    constructor(
        address _ingredientNFT,
        address _potionNFT,
        uint256 _seasonStart
    ) Ownable() {
        require(_ingredientNFT != address(0), "GameEngineV2: zero ingredientNFT");
        require(_potionNFT     != address(0), "GameEngineV2: zero potionNFT");

        ingredientNFT = IngredientNFT(_ingredientNFT);
        potionNFT     = PotionNFT(_potionNFT);

        SEASON_START = _seasonStart == 0 ? block.timestamp : _seasonStart;
    }

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier seasonActive() {
        require(block.timestamp >= SEASON_START, "GameEngineV2: season has not started");
        require(
            block.timestamp <= SEASON_START + (SEASON_DAYS * 1 days) + GRACE_PERIOD,
            "GameEngineV2: season has ended"
        );
        _;
    }

    // ─── Season Views ─────────────────────────────────────────────────────────

    /// @notice Zero-based season day. Returns 0 before the season opens.
    function currentDay() public view returns (uint256) {
        if (block.timestamp < SEASON_START) return 0;
        return (block.timestamp - SEASON_START) / 1 days;
    }

    /// @notice True while new runs may be started (excludes the grace period).
    function isSeasonActive() public view returns (bool) {
        return block.timestamp >= SEASON_START
            && block.timestamp <= SEASON_START + (SEASON_DAYS * 1 days);
    }

    function seasonEnd() external view returns (uint256) {
        return SEASON_START + (SEASON_DAYS * 1 days);
    }

    // ─── Box Layout ───────────────────────────────────────────────────────────
    /**
     * @dev Deterministic per player, per run. Base array pre-shuffle:
     *        [1,2,3,4]                 4 useful, one of each
     *        [5 x 11]                  Stone
     *        [6 x 10]                  Poison
     *      Fisher-Yates shuffled with seed = keccak256(day, player, chainId, runId).
     *      Including runId is what makes repeat runs differ; without it a player
     *      would be dealt the same board all day.
     */
    function _getBoxResource(
        address player,
        uint256 day,
        uint256 runId,
        uint8   boxIndex
    ) internal view returns (uint8) {
        uint8[25] memory base = [
            uint8(1), 2, 3, 4,
            5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
            6, 6, 6, 6, 6, 6, 6, 6, 6, 6
        ];

        bytes32 seed = keccak256(abi.encodePacked(day, player, block.chainid, runId));

        for (uint256 i = 24; i > 0; i--) {
            uint256 j  = uint256(keccak256(abi.encodePacked(seed, i))) % (i + 1);
            uint8 temp = base[i];
            base[i]    = base[j];
            base[j]    = temp;
        }

        return base[boxIndex];
    }

    /// @notice Preview the board for a run without spending gas. Useful for the UI.
    function previewRun(address player, uint256 runId) external view returns (uint8[25] memory board) {
        uint256 day = runState[player][runId].begun ? runState[player][runId].day : currentDay();
        for (uint8 i = 0; i < 25; i++) {
            board[i] = _getBoxResource(player, day, runId, i);
        }
    }

    // ─── Begin Hunt ───────────────────────────────────────────────────────────
    /**
     * @notice Opens a fresh run. Signed manually by the player.
     *
     *         Any ingredients still held are burned first. The potion recipe
     *         requires holding exactly one of each useful ingredient, so an
     *         abandoned run's leftovers would otherwise make the next run
     *         uncraftable. Starting a new run abandons any unfinished one.
     */
    function beginHunt() external nonReentrant seasonActive returns (uint256 runId) {
        address player = msg.sender;
        require(isSeasonActive(), "GameEngineV2: season closed to new runs");

        _burnAllIngredients(player);

        runId = ++currentRun[player];
        uint256 today = currentDay();

        RunState storage state = runState[player][runId];
        state.begun = true;
        state.day   = uint64(today);

        emit HuntBegun(player, runId, today);
    }

    // ─── Open Box ─────────────────────────────────────────────────────────────
    /**
     * @notice Opens a box in the caller's current run, minting one ingredient.
     * @param boxIndex which box to open (0-24), in order
     */
    function openBox(uint8 boxIndex) external nonReentrant seasonActive {
        address player = msg.sender;
        uint256 runId  = currentRun[player];
        RunState storage state = runState[player][runId];

        require(state.begun,                        "GameEngineV2: no run in progress");
        require(!state.potionCrafted,               "GameEngineV2: run already completed");
        require(boxIndex < BOXES_PER_RUN,           "GameEngineV2: invalid box index");
        require(!_isOpened(state, boxIndex),        "GameEngineV2: box already opened");

        // Sequential rule: the previous box must be closed before the next opens.
        if (boxIndex > 0) {
            require(_isClosed(state, boxIndex - 1), "GameEngineV2: must close previous box first");
        }

        uint8 resourceType = _getBoxResource(player, state.day, runId, boxIndex);

        state.opened |= uint32(1) << boxIndex;
        ingredientNFT.mint(player, resourceType, 1);

        emit BoxOpened(player, runId, boxIndex, resourceType);
    }

    // ─── Close Box ────────────────────────────────────────────────────────────
    /// @notice Marks a box closed. State only — ingredients burn in createPotion.
    function closeBox(uint8 boxIndex) external nonReentrant seasonActive {
        address player = msg.sender;
        uint256 runId  = currentRun[player];
        RunState storage state = runState[player][runId];

        require(state.begun,                 "GameEngineV2: no run in progress");
        require(boxIndex < BOXES_PER_RUN,    "GameEngineV2: invalid box index");
        require(_isOpened(state, boxIndex),  "GameEngineV2: open the box first");
        require(!_isClosed(state, boxIndex), "GameEngineV2: box already closed");

        state.closed |= uint32(1) << boxIndex;

        emit BoxClosed(player, runId, boxIndex);
    }

    // ─── Create Potion ────────────────────────────────────────────────────────
    /**
     * @notice Crafts the potion, completing the run.
     *         Requires all 25 boxes opened and closed, and exactly one of each
     *         useful ingredient held. Burns the recipe plus all junk, mints one
     *         Potion NFT, and credits points.
     *
     *         The player may immediately call beginHunt() again.
     */
    function createPotion() external nonReentrant seasonActive returns (uint256 tokenId) {
        address player = msg.sender;
        uint256 runId  = currentRun[player];
        RunState storage state = runState[player][runId];

        require(state.begun,               "GameEngineV2: no run in progress");
        require(!state.potionCrafted,      "GameEngineV2: potion already crafted for this run");
        require(state.opened == ALL_BOXES, "GameEngineV2: not all boxes have been opened");
        require(state.closed == ALL_BOXES, "GameEngineV2: not all boxes have been closed");

        require(ingredientNFT.balanceOf(player, WATER)      == 1, "GameEngineV2: need exactly 1 Water");
        require(ingredientNFT.balanceOf(player, CRYSTALIX)  == 1, "GameEngineV2: need exactly 1 Crystalix");
        require(ingredientNFT.balanceOf(player, SUNFIBER)   == 1, "GameEngineV2: need exactly 1 Sunfiber");
        require(ingredientNFT.balanceOf(player, COPPERVEIN) == 1, "GameEngineV2: need exactly 1 Coppervein");

        // Mark complete before external calls.
        state.potionCrafted = true;

        ingredientNFT.burn(player, WATER,      1);
        ingredientNFT.burn(player, CRYSTALIX,  1);
        ingredientNFT.burn(player, SUNFIBER,   1);
        ingredientNFT.burn(player, COPPERVEIN, 1);

        uint256 stoneBalance  = ingredientNFT.balanceOf(player, STONE);
        uint256 poisonBalance = ingredientNFT.balanceOf(player, POISON);
        if (stoneBalance  > 0) ingredientNFT.burn(player, STONE,  stoneBalance);
        if (poisonBalance > 0) ingredientNFT.burn(player, POISON, poisonBalance);

        totalSeasonPoints[player] += POINTS_PER_POTION;
        potionsCrafted[player]    += 1;

        tokenId = potionNFT.mint(player);

        emit PotionCrafted(player, runId, POINTS_PER_POTION, tokenId);
    }

    // ─── Player Views ─────────────────────────────────────────────────────────

    /// @notice Progress of the caller-supplied player's current run.
    function getRunProgress(address player)
        external
        view
        returns (
            uint256 runId,
            uint32  opened,
            uint32  closed,
            uint8   boxesOpened,
            uint8   boxesClosed,
            bool    begun,
            bool    potionCrafted,
            bool    readyToCraft
        )
    {
        runId = currentRun[player];
        RunState storage state = runState[player][runId];

        opened        = state.opened;
        closed        = state.closed;
        begun         = state.begun;
        potionCrafted = state.potionCrafted;
        boxesOpened   = _popcount25(state.opened);
        boxesClosed   = _popcount25(state.closed);
        readyToCraft  = begun
            && !potionCrafted
            && state.opened == ALL_BOXES
            && state.closed == ALL_BOXES;
    }

    /// @notice Season tallies for one player.
    function getSeasonStats(address player)
        external
        view
        returns (uint256 points, uint256 potions)
    {
        points  = totalSeasonPoints[player];
        potions = potionsCrafted[player];
    }

    function isBoxOpened(address player, uint256 runId, uint8 boxIndex) external view returns (bool) {
        return _isOpened(runState[player][runId], boxIndex);
    }

    function isBoxClosed(address player, uint256 runId, uint8 boxIndex) external view returns (bool) {
        return _isClosed(runState[player][runId], boxIndex);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setIngredientNFT(address _ingredientNFT) external onlyOwner {
        require(_ingredientNFT != address(0), "GameEngineV2: zero ingredientNFT");
        ingredientNFT = IngredientNFT(_ingredientNFT);
        emit IngredientNFTUpdated(_ingredientNFT);
    }

    function setPotionNFT(address _potionNFT) external onlyOwner {
        require(_potionNFT != address(0), "GameEngineV2: zero potionNFT");
        potionNFT = PotionNFT(_potionNFT);
        emit PotionNFTUpdated(_potionNFT);
    }

    // ─── Internals ────────────────────────────────────────────────────────────

    function _isOpened(RunState storage state, uint8 boxIndex) private view returns (bool) {
        return (state.opened >> boxIndex) & 1 == 1;
    }

    function _isClosed(RunState storage state, uint8 boxIndex) private view returns (bool) {
        return (state.closed >> boxIndex) & 1 == 1;
    }

    function _burnAllIngredients(address player) private {
        for (uint256 id = WATER; id <= POISON; id++) {
            uint256 balance = ingredientNFT.balanceOf(player, id);
            if (balance > 0) {
                ingredientNFT.burn(player, id, balance);
            }
        }
    }

    function _popcount25(uint32 mask) private pure returns (uint8 count) {
        for (uint8 i = 0; i < 25; i++) {
            if ((mask >> i) & 1 == 1) count++;
        }
    }
}
