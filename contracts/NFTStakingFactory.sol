// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./NFTStaking.sol";

contract NFTStakingFactory is Ownable {
    event NewNFTStakingContract(address indexed nftStaking);

    /*
     * @notice Deploy the pool
     * @param _stakedToken: staked token address
     * @param _rewardToken: reward token address
     * @param _rewardPerBlock: reward per block (in rewardToken)
     * @param _startBlock: start block
     * @param _endBlock: end block
     * @param _poolLimitPerUser: pool limit per user in stakedToken (if any, else 0)
     * @param _stakedTokenTransferFee: the transfer fee of stakedToken (if any, else 0)
     * @param _withdrawalInterval: the withdrawal interval for stakedToken (if any, else 0)
     * @param _admin: admin address with ownership
     * @return address of new panther jungle contract
     */
    function deployPool(
        IERC20 _rewardsToken,
        IERC721 _parentNFT,
        IContribution _iCont,
        uint256 _rewardRate,
        address _admin
    ) external onlyOwner {
        bytes memory bytecode = type(NFTStaking).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(_rewardsToken, _parentNFT, _rewardRate));
        address nftStakingAddress;

        assembly {
            nftStakingAddress := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        NFTStaking(nftStakingAddress).initialize(
            _rewardsToken,
            _parentNFT,
            _iCont,
            _rewardRate,
            _admin
        );

        emit NewNFTStakingContract(nftStakingAddress);
    }
}
