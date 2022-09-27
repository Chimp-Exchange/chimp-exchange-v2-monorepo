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

import "@balancer-labs/v2-interfaces/contracts/solidity-utils/openzeppelin/IERC20.sol";

interface IControlledManagedPool {
    function updateWeightsGradually(
        uint256 startTime,
        uint256 endTime,
        IERC20[] calldata tokens,
        uint256[] calldata endWeights
    ) external;

    function setSwapEnabled(bool swapEnabled) external;

    function addAllowedAddress(address member) external;

    function removeAllowedAddress(address member) external;

    function setMustAllowlistLPs(bool mustAllowlistLPs) external;

    function collectAumManagementFees() external returns (uint256);

    function setManagementAumFeePercentage(uint256 managementAumFeePercentage) external returns (uint256);
}
