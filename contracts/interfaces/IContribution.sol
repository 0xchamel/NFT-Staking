pragma solidity ^0.8.0;

interface IContribution {
    function getPoint(uint256 tokenId) external view returns (uint256);
}
