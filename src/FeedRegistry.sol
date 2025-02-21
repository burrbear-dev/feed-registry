// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "amm-contracts/contracts/FXPoolDeployer.sol";

/**
 * @title FeedRegistry
 * @notice A registry for Chainlink price feeds with associated ERC20 base tokens and FXPoolDeployer integration
 */
contract FeedRegistry is OwnableUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    address public feedRegistry;

    EnumerableSet.AddressSet private _deployers;

    EnumerableSet.AddressSet private _approvedFeeds;

    EnumerableSet.AddressSet private _pendingFeeds;
    // deployer => list of baseFeed
    mapping(address => EnumerableSet.AddressSet) internal _deployerFeeds;
    // quoteToken => deployer
    mapping(address => address) public quoteTokenToDeployer;

    event FeedSuggested(address indexed suggester, address indexed baseFeed);

    event FeedApproved(address indexed quoteToken, address indexed baseFeed);

    function __FeedRegistry_init(address _feedRegistry) internal initializer {
        __Ownable_init();
        feedRegistry = _feedRegistry;
    }

    /**
     * @notice Suggests a new feed to be added to the registry
     * @param baseFeed The address of the Chainlink price feed
     */
    function suggestFeed(address baseFeed) external {
        require(_isFeedValid(baseFeed), "Invalid address");

        require(!_approvedFeeds.contains(baseFeed), "Feed already exists");

        _pendingFeeds.add(baseFeed);

        emit FeedSuggested(msg.sender, baseFeed);
    }

    /**
     * @notice Approves a pending feed
     * @param baseFeed The address of the Chainlink price feed
     * @param quoteToken The address of the quote token
     */
    function approveFeed(address baseFeed, address quoteToken) external onlyOwner {
        require(_isTokenValid(quoteToken), "Invalid address");

        require(_pendingFeeds.contains(baseFeed), "Feed does not exist");

        address deployer = quoteTokenToDeployer[quoteToken];

        if (!_deployers.contains(deployer)) {
            // deploy new fx pool deployer using proxy
            // set deployer with new deployed address
            // update quoteTokenToDeployer[quoteToken]
            // add deployer to the list
        }
        _pendingFeeds.remove(baseFeed);
        _approvedFeeds.add(baseFeed);

        _deployerFeeds[deployer].add(baseFeed);

        // call adminApproveBaseOracle on deployer
        bytes memory data = abi.encodePacked(
            bytes4(keccak256("adminApproveBaseOracle(address)")),
            abi.encode(baseFeed)
        );
        _callDeployer(deployer, data);

        emit FeedApproved(quoteToken, baseFeed);
    }

    /// @dev helper function to call a function on a deployer
    function _callDeployer(address deployer, bytes memory data) private {
        (bool success, bytes memory returnData) = deployer.call(data);
        if (!success) {
            // If there is return data, try to extract and revert with the original error message
            if (returnData.length > 0) {
                assembly {
                    let returnDataSize := mload(returnData)
                    revert(add(32, returnData), returnDataSize)
                }
            } else {
                revert("Call to deployer failed");
            }
        }
    }

    function _isTokenValid(address tokenAddress) private view returns (bool) {
        if (tokenAddress == address(0)) return false;
        try IERC20(tokenAddress).totalSupply() returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    function _isFeedValid(address feedAddress) private view returns (bool) {
        if (feedAddress == address(0)) return false;
        return IFeedRegistry(feedRegistry).isFeedEnabled(feedAddress);
    }
}

interface IFeedRegistry {
    function isFeedEnabled(address aggregator) external view returns (bool);
}
