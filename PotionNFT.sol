// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PotionNFT
 * @notice ERC-721 contract for the crafted Rumble Potion.
 *         Only the GameEngine contract can mint.
 *         Players accumulate one potion per successful daily craft.
 *         Holding this NFT grants 100 free game sessions (checked by backend).
 */
contract PotionNFT is ERC721, Ownable {

    address public gameEngine;
    uint256 private _tokenIdCounter;

    string private _baseTokenURI;

    // ─── Events ───────────────────────────────────────────────────────────────
    event GameEngineSet(address indexed gameEngine);

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyGameEngine() {
        require(msg.sender == gameEngine, "PotionNFT: caller is not GameEngine");
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(string memory baseURI_)
        ERC721("Rumble Potion", "RPOTION")
        Ownable()
    {
        _baseTokenURI = baseURI_;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────
    function setGameEngine(address _gameEngine) external onlyOwner {
        require(_gameEngine != address(0), "PotionNFT: zero address");
        gameEngine = _gameEngine;
        emit GameEngineSet(_gameEngine);
    }

    function setBaseURI(string memory newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
    }

    // ─── GameEngine-Only Functions ────────────────────────────────────────────
    function mint(address to) external onlyGameEngine returns (uint256 tokenId) {
        tokenId = ++_tokenIdCounter;
        _safeMint(to, tokenId);
    }

    // ─── View Helpers ─────────────────────────────────────────────────────────
    function totalSupply() external view returns (uint256) {
        return _tokenIdCounter;
    }

    // Every potion shares identical art/metadata and supply is uncapped, so
    // tokenURI ignores the id instead of the OZ default of baseURI + id —
    // that would require pre-pinning one IPFS file per token id forever.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "ERC721: invalid token ID");
        return _baseTokenURI;
    }
}
