// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./interfaces/IContribution.sol";

contract NFTStaking is Ownable, ReentrancyGuard {
    bytes4 private constant _ERC721_RECEIVED = 0x150b7a02;

    IERC20 public rewardsToken;
    IERC721 public parentNFT;
    IContribution public iCont;

    /// @notice total ethereum staked currently in the gensesis staking contract
    uint256 public stakedPointTotal;
    uint256 public lastUpdateTime;

    uint256 public rewardsPerTokenPoints;
    uint256 public totalUnclaimedRewards;

    uint256 constant pointMultiplier = 10e18;
    uint256 public rewardRate; // 1 tokens per sec = 86400 tokens per day

    /**
    @notice Struct to track what user is staking which tokens
    @dev tokenIds are all the tokens staked by the staker
    @dev balance is the current ether balance of the staker
    @dev rewardsEarned is the total reward for the staker till now
    @dev rewardsReleased is how much reward has been paid to the staker
    */
    struct Staker {
        uint256[] tokenIds;
        mapping(uint256 => uint256) tokenIndex;
        uint256 balance;
        uint256 lastRewardPoints;
        uint256 rewardsEarned;
        uint256 rewardsReleased;
    }

    /// @notice mapping of a staker to its current properties
    mapping(address => Staker) public stakers;

    // Mapping from token ID to owner address
    mapping(uint256 => address) public tokenOwner;

    /// @notice sets the token to be claimable or not, cannot claim if it set to false
    bool public tokensClaimable;

    /// @notice sets the contract is initialized or not
    bool private initialized;

    /// @notice event emitted when a user has staked a token
    event Staked(address owner, uint256 amount);

    /// @notice event emitted when a user has unstaked a token
    event Unstaked(address owner, uint256 amount);

    /// @notice event emitted when a user claims reward
    event RewardPaid(address indexed user, uint256 reward);

    /// @notice Allows reward tokens to be claimed
    event ClaimableStatusUpdated(bool status);

    /// @notice Emergency unstake tokens without rewards
    event EmergencyUnstake(address indexed user, uint256 tokenId);

    /// @notice Admin update of rewards contract
    event RewardsTokenUpdated(address indexed oldRewardsToken, address newRewardsToken);

    function initialize(
        IERC20 _rewardsToken,
        IERC721 _parentNFT,
        IContribution _iCont,
        uint256 _rewardRate,
        address _admin
    ) external {
        require(!initialized, "Already Initialized");
        initialized = true;

        iCont = _iCont;
        parentNFT = _parentNFT;
        rewardRate = _rewardRate;
        rewardsToken = _rewardsToken;
        lastUpdateTime = block.timestamp;

        transferOwnership(_admin);
    }

    /// @notice Sets the new reward rate
    function setRewardRate(uint256 rewardRate_) external onlyOwner {
        require(rewardRate_ != 0, "Cannot have reward Rate 0");
        rewardRate = rewardRate_;
    }

    /// @notice Lets admin set the Rewards to be claimable
    function setTokensClaimable(bool _enabled) external onlyOwner {
        tokensClaimable = _enabled;
        emit ClaimableStatusUpdated(_enabled);
    }

    /// @dev Getter functions for Staking contract
    /// @dev Get the tokens staked by a user
    function getStakedTokens(address _user) external view returns (uint256[] memory tokenIds) {
        return stakers[_user].tokenIds;
    }

    /// @dev Get the amount a staked nft is valued at ie bought at
    function getContribution(uint256 _tokenId) public view returns (uint256) {
        return iCont.getPoint(_tokenId);
    }

    /// @notice Stake MONA NFTs and earn reward tokens.
    function stake(uint256 tokenId) external {
        _stake(msg.sender, tokenId);
    }

    /**
     * @dev All the staking goes through this function
     * @dev Rewards to be given out is calculated
     * @dev Balance of stakers are updated as they stake the nfts based on ether price
     */
    function _stake(address _user, uint256 _tokenId) internal {
        Staker storage staker = stakers[_user];

        if (staker.balance == 0 && staker.lastRewardPoints == 0) {
            staker.lastRewardPoints = rewardsPerTokenPoints;
        }

        updateReward(_user);
        uint256 amount = getContribution(_tokenId);
        staker.balance += amount;
        stakedPointTotal += amount;
        staker.tokenIds.push(_tokenId);
        staker.tokenIndex[staker.tokenIds.length - 1];
        tokenOwner[_tokenId] = _user;
        parentNFT.safeTransferFrom(_user, address(this), _tokenId);

        emit Staked(_user, _tokenId);
    }

    /// @notice Unstake Genesis MONA NFTs.
    function unstake(uint256 _tokenId) external {
        require(
            tokenOwner[_tokenId] == msg.sender,
            "NFTStaking._unstake: Sender must have staked tokenID"
        );
        claimReward(msg.sender);
        _unstake(msg.sender, _tokenId);
    }

    /**
     * @dev All the unstaking goes through this function
     * @dev Rewards to be given out is calculated
     * @dev Balance of stakers are updated as they unstake the nfts based on ether price
     */
    function _unstake(address _user, uint256 _tokenId) internal {
        Staker storage staker = stakers[_user];

        uint256 amount = getContribution(_tokenId);
        staker.balance -= amount;
        stakedPointTotal -= amount;

        uint256 lastIndex = staker.tokenIds.length - 1;
        uint256 lastIndexKey = staker.tokenIds[lastIndex];
        uint256 tokenIdIndex = staker.tokenIndex[_tokenId];

        staker.tokenIds[tokenIdIndex] = lastIndexKey;
        staker.tokenIndex[lastIndexKey] = tokenIdIndex;
        if (staker.tokenIds.length > 0) {
            staker.tokenIds.pop();
            delete staker.tokenIndex[_tokenId];
        }

        if (staker.balance == 0) {
            delete stakers[_user];
        }
        delete tokenOwner[_tokenId];

        parentNFT.safeTransferFrom(address(this), _user, _tokenId);

        emit Unstaked(_user, _tokenId);
    }

    // Unstake without caring about rewards. EMERGENCY ONLY.
    function emergencyUnstake(uint256 _tokenId) public {
        require(
            tokenOwner[_tokenId] == msg.sender,
            "NFTStaking._unstake: Sender must have staked tokenID"
        );
        _unstake(msg.sender, _tokenId);
        emit EmergencyUnstake(msg.sender, _tokenId);
    }

    /// @dev Updates the amount of rewards owed for each user before any tokens are moved
    function updateReward(address _user) public {
        uint256 parentRewards = (block.timestamp - lastUpdateTime) * rewardRate;

        if (stakedPointTotal > 0) {
            rewardsPerTokenPoints += (parentRewards * pointMultiplier) / stakedPointTotal;
        }

        lastUpdateTime = block.timestamp;
        uint256 rewards = rewardsOwing(_user);

        Staker storage staker = stakers[_user];
        if (_user != address(0)) {
            staker.rewardsEarned += rewards;
            staker.lastRewardPoints = rewardsPerTokenPoints;
        }
    }

    /// @notice Returns the rewards owing for a user
    /// @dev The rewards are dynamic and normalised from the other pools
    /// @dev This gets the rewards from each of the periods as one multiplier
    function rewardsOwing(address _user) public view returns (uint256) {
        uint256 newRewardPerToken = rewardsPerTokenPoints - stakers[_user].lastRewardPoints;
        uint256 rewards = (stakers[_user].balance * newRewardPerToken) / 1e18 / pointMultiplier;
        return rewards;
    }

    /// @notice Returns the about of rewards yet to be claimed
    function pendingReward(address _user) external view returns (uint256) {
        if (stakedPointTotal == 0) {
            return 0;
        }

        uint256 parentRewards = (block.timestamp - lastUpdateTime) * rewardRate;

        uint256 newRewardPerToken = rewardsPerTokenPoints +
            ((parentRewards * pointMultiplier) / stakedPointTotal) -
            (stakers[_user].lastRewardPoints);

        uint256 rewards = (stakers[_user].balance * newRewardPerToken) / 1e18 / pointMultiplier;
        return rewards + stakers[_user].rewardsEarned - stakers[_user].rewardsReleased;
    }

    /// @notice Lets a user with rewards owing to claim tokens
    function claimReward(address _user) public {
        require(tokensClaimable == true, "Tokens cannnot be claimed yet");
        updateReward(_user);

        Staker storage staker = stakers[_user];

        uint256 payableAmount = staker.rewardsEarned - (staker.rewardsReleased);
        staker.rewardsReleased += payableAmount;

        /// @dev accounts for dust
        uint256 rewardBal = rewardsToken.balanceOf(address(this));
        if (payableAmount > rewardBal) {
            payableAmount = rewardBal;
        }

        rewardsToken.transfer(_user, payableAmount);
        emit RewardPaid(_user, payableAmount);
    }

    /// @notice ERC721 tokens receiver
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) public returns (bytes4) {
        return _ERC721_RECEIVED;
    }
}
