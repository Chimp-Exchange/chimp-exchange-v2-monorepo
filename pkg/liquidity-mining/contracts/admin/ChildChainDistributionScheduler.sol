// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "@balancer-labs/v2-solidity-utils/contracts/helpers/Authentication.sol";
import "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/SafeERC20.sol";

import "../interfaces/IAuthorizerAdaptor.sol";
import "../interfaces/IRewardsOnlyGauge.sol";

// solhint-disable not-rely-on-time

/**
 * @title ChildChainDistributionScheduler
 * @notice Scheduler for setting up permissionless distributions of liquidity gauge reward tokens.
 * @dev Any address may send tokens to the DistributionSchedule to be distributed among gauge depositors.
 */
contract ChildChainDistributionScheduler is Authentication {
    using SafeERC20 for IERC20;

    uint256 private constant _MAX_REWARDS = 8;

    // The node at _HEAD contains no value, and simply points to the actual first node. The last node points to _NULL.
    uint32 private constant _HEAD = 0;
    uint32 private constant _NULL = 0;

    // gauge-token pair -> timestamp -> (amount, nextTimestamp)
    mapping(bytes32 => mapping(uint32 => RewardNode)) private _rewardsLists;

    struct RewardNode {
        uint224 amount;
        uint32 nextTimestamp;
    }

    IVault private immutable _vault;
    IAuthorizerAdaptor private immutable _authorizerAdaptor;

    constructor(IAuthorizerAdaptor authorizerAdaptor) Authentication(bytes32(uint256(address(this)))) {
        // ChildChainDistributionScheduler is a singleton, so it uses its own address to disambiguate action identifiers

        _vault = authorizerAdaptor.getVault();
        _authorizerAdaptor = authorizerAdaptor;
    }

    /**
     * @notice Returns the Balancer Vault
     */
    function getVault() public view returns (IVault) {
        return _vault;
    }

    /**
     * @notice Returns the Balancer Vault's current authorizer.
     */
    function getAuthorizer() public view returns (IAuthorizer) {
        return getVault().getAuthorizer();
    }


    /**
     * @notice Returns information on the reward paid out to `gauge` in `token` over the week starting at `timestamp`
     * @param gauge - The gauge which is to distribute the reward token.
     * @param token - The token which is to be distributed among gauge depositors.
     * @param timestamp - The timestamp corresponding to the beginning of the week being queried.
     * @return - the amount of `token` which is to be distributed over the week starting at `timestamp`.
     *         - the timestamp of the next scheduled distribution of `token` to `gauge`. Zero if no distribution exists.
     */
    function getRewardNode(
        IRewardsOnlyGauge gauge,
        IERC20 token,
        uint256 timestamp
    ) external view returns (RewardNode memory) {
        return _rewardsLists[_getRewardsListId(gauge, token)][uint32(timestamp)];
    }

    /**
     * @notice Returns the amount of `token` which is ready to be distributed by `gauge` as of the current timestamp.
     * @param gauge - The gauge which is to distribute the reward token.
     * @param token - The token which is to be distributed among gauge depositors.
     */
    function getPendingRewards(IRewardsOnlyGauge gauge, IERC20 token) public view returns (uint256) {
        return getPendingRewardsAt(gauge, token, block.timestamp);
    }

    /**
     * @notice Returns the amount of `token` which is ready to be distributed by `gauge` as of a specified timestamp.
     * @param gauge - The gauge which is to distribute the reward token.
     * @param token - The token which is to be distributed among gauge depositors.
     * @param timestamp - The future timestamp in which to query.
     */
    function getPendingRewardsAt(
        IRewardsOnlyGauge gauge,
        IERC20 token,
        uint256 timestamp
    ) public view returns (uint256) {
        mapping(uint32 => RewardNode) storage rewardsList = _rewardsLists[_getRewardsListId(gauge, token)];

        (, uint256 amount) = _getPendingRewards(rewardsList, timestamp);
        return amount;
    }

    /**
     * @notice Schedule a distribution of tokens to gauge depositors over the span of 1 week.
     * @dev All distributions must start at the beginning of a week in UNIX time, i.e. Thurs 00:00 UTC.
     * This is to prevent griefing from many low value distributions having to be processed before a meaningful
     * distribution can be processed.
     * @param gauge - The gauge which is to distribute the reward token.
     * @param token - The token which is to be distributed among gauge depositors.
     * @param amount - The amount of tokens which to distribute.
     * @param startTime - The timestamp at the beginning of the week over which to distribute tokens.
     */
    function scheduleDistribution(
        IRewardsOnlyGauge gauge,
        IERC20 token,
        uint256 amount,
        uint256 startTime
    ) external {
        require(amount > 0, "Must provide non-zero number of tokens");

        // Ensure that values won't overflow when put into storage.
        require(amount <= type(uint224).max, "Reward amount overflow");
        require(startTime <= type(uint32).max, "Reward timestamp overflow");

        // Ensure that a user doesn't add a reward token which becomes locked on scheduler
        address rewardDistributor = gauge.reward_data(token).distributor;
        require(rewardDistributor != address(0), "Reward token does not exist on gauge");

        // Prevent griefing by creating many small distributions which must be processed.
        require(startTime >= block.timestamp, "Distribution can only be scheduled for the future");
        require(startTime == _roundDownTimestamp(startTime), "Distribution must start at the beginning of the week");

        token.safeTransferFrom(msg.sender, address(this), amount);

        _insertReward(_rewardsLists[_getRewardsListId(gauge, token)], uint32(startTime), uint224(amount));
    }

    /**
     * @notice Process all pending distributions for a gauge to start distributing the tokens.
     * @param gauge - The gauge which is to distribute the reward token.
     */
    function startDistributions(IRewardsOnlyGauge gauge) external {
        for (uint256 i = 0; i < _MAX_REWARDS; ++i) {
            IERC20 token = gauge.reward_tokens(i);
            if (token == IERC20(0)) break;

            // Check to ensure that the token has not been removed from the streamer's list of reward tokens.
            // Not doing this risks locking tokens onto the streamer.
            address distributor = gauge.reward_contract().reward_data(token).distributor;
            if (distributor != address(0)) {
                startDistributionForToken(gauge, token);
            }
        }
    }

    /**
     * @notice Process all pending distributions for a given token for a gauge to start distributing tokens.
     * @param gauge - The gauge which is to distribute the reward token.
     * @param token - The token which is to be distributed among gauge depositors.
     */
    function startDistributionForToken(IRewardsOnlyGauge gauge, IERC20 token) public {
        IChildChainStreamer streamer = gauge.reward_contract();
        IChildChainStreamer.RewardToken memory rewardData = streamer.reward_data(token);
        require(rewardData.distributor != address(0), "Reward token does not exist on gauge");

        mapping(uint32 => RewardNode) storage rewardsList = _rewardsLists[_getRewardsListId(gauge, token)];

        (uint32 firstUnprocessedNodeKey, uint256 rewardAmount) = _getPendingRewards(rewardsList, block.timestamp);

        // These calls are reentrancy-safe as we've already performed our only state transition (updating the head of
        // the list)
        rewardsList[_HEAD].nextTimestamp = firstUnprocessedNodeKey;

        if (rewardAmount > 0) {
            token.transfer(address(streamer), rewardAmount);

            // If we're able to, notify the streamer to begin distributing these tokens.
            if (rewardData.distributor == address(this) || rewardData.period_finish < block.timestamp) {
                streamer.notify_reward_amount(token);
            }
        }
    }

    /**
     * @notice Recover any tokens held as pending rewards which can no longer be paid out to the desired gauge.
     * @param gauge - The gauge to which the tokens were to be distributed.
     * @param token - The token which is to be recovered.
     * @param recipient - The address to which to send the recovered tokens
     */
    function recoverInvalidPendingRewards(
        IRewardsOnlyGauge gauge,
        IERC20 token,
        address recipient
    ) external authenticate {
        IChildChainStreamer streamer = gauge.reward_contract();
        IChildChainStreamer.RewardToken memory rewardData = streamer.reward_data(token);
        require(rewardData.distributor == address(0), "Reward token can still be distributed to gauge");

        mapping(uint32 => RewardNode) storage rewardsList = _rewardsLists[_getRewardsListId(gauge, token)];

        // We claim all pending reward distributions, not just those which would be ready to be started.
        (uint32 firstUnprocessedNodeKey, uint256 rewardAmount) = _getPendingRewards(rewardsList, type(uint256).max);

        // These calls are reentrancy-safe as we've already performed our only state transition (updating the head of
        // the list)
        rewardsList[_HEAD].nextTimestamp = firstUnprocessedNodeKey;

        token.transfer(recipient, rewardAmount);
    }

    // Internal functions

    function _getRewardsListId(IRewardsOnlyGauge gauge, IERC20 rewardToken) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(gauge, rewardToken));
    }

    /**
     * @dev Sums the rewards held on all pending reward nodes with a key lesser than `targetKey`.
     * @return - the key corresponding to the first node with a key greater than `targetKey`.
     *         - the cumulative rewards held on all pending nodes before `targetKey`
     */
    function _getPendingRewards(mapping(uint32 => RewardNode) storage rewardsList, uint256 targetKey)
        internal
        view
        returns (uint32, uint256)
    {
        uint32 currentNodeKey = rewardsList[_HEAD].nextTimestamp;

        // Iterate through all nodes which are ready to be started, summing the values of each.
        uint256 amount;
        while (targetKey >= currentNodeKey && currentNodeKey != _NULL) {
            amount += rewardsList[currentNodeKey].amount;

            currentNodeKey = rewardsList[currentNodeKey].nextTimestamp;
        }

        return (currentNodeKey, amount);
    }

    /**
     * @dev Find the position of the new node in the list of pending nodes and insert it.
     */
    function _insertReward(
        mapping(uint32 => RewardNode) storage rewardsList,
        uint32 insertedNodeKey,
        uint224 amount
    ) private {
        // We want to find two nodes which sit either side of the new node to be created so we can insert between them.

        uint32 currentNodeKey = _HEAD;
        uint32 nextNodeKey = rewardsList[currentNodeKey].nextTimestamp;

        // Search through nodes until the new node sits somewhere between `currentNodeKey` and `nextNodeKey`, or
        // we process all nodes.
        while (insertedNodeKey > nextNodeKey && nextNodeKey != _NULL) {
            currentNodeKey = nextNodeKey;
            nextNodeKey = rewardsList[currentNodeKey].nextTimestamp;
        }

        if (nextNodeKey == _NULL) {
            // We reached the end of the list and so can just append the new node.
            rewardsList[currentNodeKey].nextTimestamp = insertedNodeKey;
            rewardsList[insertedNodeKey] = RewardNode(amount, _NULL);
        } else if (nextNodeKey == insertedNodeKey) {
            // There already exists a node at the time we want to insert one.
            // We then just increase the value of this node.

            uint256 rewardAmount = uint256(rewardsList[nextNodeKey].amount) + amount;
            require(rewardAmount <= type(uint224).max, "Reward amount overflow");
            rewardsList[nextNodeKey].amount = uint224(rewardAmount);
        } else {
            // We're inserting a node in between `currentNodeKey` and `nextNodeKey` so then update
            // `currentNodeKey` to point to the newly inserted node and the new node to point to `nextNodeKey`.
            rewardsList[insertedNodeKey] = RewardNode(amount, nextNodeKey);
            rewardsList[currentNodeKey].nextTimestamp = insertedNodeKey;
        }
    }

    /**
     * @dev Rounds the provided timestamp down to the beginning of the previous week (Thurs 00:00 UTC)
     */
    function _roundDownTimestamp(uint256 timestamp) private pure returns (uint256) {
        return (timestamp / 1 weeks) * 1 weeks;
    }

    function _canPerform(bytes32 actionId, address account) internal view override returns (bool) {
        return getAuthorizer().canPerform(actionId, account, address(this));
    }
}
