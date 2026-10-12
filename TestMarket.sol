// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title TestMarket
 * @notice A minimal, standalone test harness for the Predictions deposit ->
 *         predict -> withdraw flow, deployed on Avalanche Fuji where AVAX is
 *         the native gas token (18 decimals) — deposits/withdrawals are plain
 *         native-value transfers, no ERC20 approve step.
 *
 *         There is no real matchroom to resolve against yet, so `predict`
 *         intentionally does NOT lock or escrow funds — it only records which
 *         side a caller picked. Every depositor can withdraw their full
 *         balance at any time regardless of what they've predicted. This is
 *         a plumbing test (can AVAX move in, get referenced by a prediction,
 *         and move back out) — not a rehearsal of the parimutuel payout math,
 *         which needs a real match to resolve against (see PredictionMarket.sol).
 */
contract TestMarket is ReentrancyGuard {

    // ─── Constants ────────────────────────────────────────────────────────────
    uint8 public constant TEAM_A = 0;
    uint8 public constant TEAM_B = 1;

    // ─── State ────────────────────────────────────────────────────────────────
    mapping(address => uint256) public balanceOf;
    mapping(address => uint8) public predictedTeam;
    mapping(address => bool) public hasPredicted;

    // ─── Events ───────────────────────────────────────────────────────────────
    event Deposited(address indexed user, uint256 amount);
    event PredictionRecorded(address indexed user, uint8 indexed team);
    event Withdrawn(address indexed user, uint256 amount);

    /** @notice Deposit native AVAX into your test balance. */
    function deposit() external payable {
        require(msg.value > 0, "TestMarket: deposit must be > 0");
        balanceOf[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    /** @notice Record which team you predict wins the test room. Does not lock funds. */
    function predict(uint8 team) external {
        require(team == TEAM_A || team == TEAM_B, "TestMarket: invalid team");
        predictedTeam[msg.sender] = team;
        hasPredicted[msg.sender] = true;
        emit PredictionRecorded(msg.sender, team);
    }

    /** @notice Withdraw any amount up to your full deposited balance, any time. */
    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0 && amount <= balanceOf[msg.sender], "TestMarket: invalid withdraw amount");
        balanceOf[msg.sender] -= amount;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "TestMarket: withdraw transfer failed");
        emit Withdrawn(msg.sender, amount);
    }
}
