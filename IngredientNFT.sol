// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title IngredientNFT
 * @notice ERC-1155 contract for all 6 ingredient types.
 *         Only the GameEngine contract can mint or burn.
 *
 *  Token IDs:
 *    1 = Water       (useful)
 *    2 = Crystalix   (useful)
 *    3 = Sunfiber    (useful)
 *    4 = Coppervein  (useful)
 *    5 = Stone       (useless)
 *    6 = Poison      (useless)
 */
contract IngredientNFT is ERC1155, Ownable {

    // ─── Token IDs ────────────────────────────────────────────────────────────
    uint256 public constant WATER      = 1;
    uint256 public constant CRYSTALIX  = 2;
    uint256 public constant SUNFIBER   = 3;
    uint256 public constant COPPERVEIN = 4;
    uint256 public constant STONE      = 5;
    uint256 public constant POISON     = 6;

    address public gameEngine;

    // ─── Events ───────────────────────────────────────────────────────────────
    event GameEngineSet(address indexed gameEngine);

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyGameEngine() {
        require(msg.sender == gameEngine, "IngredientNFT: caller is not GameEngine");
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(string memory uri_) ERC1155(uri_) Ownable() {}

    // ─── Admin ────────────────────────────────────────────────────────────────
    function setGameEngine(address _gameEngine) external onlyOwner {
        require(_gameEngine != address(0), "IngredientNFT: zero address");
        gameEngine = _gameEngine;
        emit GameEngineSet(_gameEngine);
    }

    function setURI(string memory newUri) external onlyOwner {
        _setURI(newUri);
    }

    // ─── GameEngine-Only Functions ────────────────────────────────────────────
    function mint(address to, uint256 id, uint256 amount) external onlyGameEngine {
        require(id >= 1 && id <= 6, "IngredientNFT: invalid token id");
        _mint(to, id, amount, "");
    }

    function burn(address from, uint256 id, uint256 amount) external onlyGameEngine {
        require(id >= 1 && id <= 6, "IngredientNFT: invalid token id");
        _burn(from, id, amount);
    }

    // ─── View Helpers ─────────────────────────────────────────────────────────
    function ingredientName(uint256 id) external pure returns (string memory) {
        if (id == WATER)      return "Water";
        if (id == CRYSTALIX)  return "Crystalix";
        if (id == SUNFIBER)   return "Sunfiber";
        if (id == COPPERVEIN) return "Coppervein";
        if (id == STONE)      return "Stone";
        if (id == POISON)     return "Poison";
        return "Unknown";
    }

    function isUseful(uint256 id) external pure returns (bool) {
        return id >= 1 && id <= 4;
    }

    // Returns all 6 balances for a player in one call
    // [water, crystalix, sunfiber, coppervein, stone, poison]
    function getAllBalances(address player) external view returns (uint256[6] memory balances) {
        for (uint256 i = 0; i < 6; i++) {
            balances[i] = balanceOf(player, i + 1);
        }
    }
}
