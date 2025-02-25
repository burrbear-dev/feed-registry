// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/ProxyAdmin.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import { IOracle } from "amm-contracts/contracts/core/interfaces/IOracle.sol";
import { BaseToUsdAssimilator } from "amm-contracts/contracts/assimilators/BaseToUsdAssimilator.sol";
import { UsdcToUsdAssimilator } from "amm-contracts/contracts/assimilators/UsdcToUsdAssimilator.sol";

/**
 * @title FeedRegistry
 * @notice A registry for Chainlink price feeds with associated ERC20 base tokens and FXPoolDeployer integration
 */
contract FeedRegistry is OwnableUpgradeable {
    using Math for uint256;
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    ProxyAdmin internal _upgrader;
    address public chainLnkFeedRegistry;
    address internal fxPoolDeployerImpl;

    // list of deployer proxy addresses
    EnumerableSet.AddressSet internal _deployers;
    // list of approved chainlink feeds
    EnumerableSet.AddressSet internal _approvedFeeds;
    // list of pending chainlink feeds
    EnumerableSet.AddressSet internal _pendingFeeds;
    // deployer => list of baseFeed
    mapping(address => EnumerableSet.AddressSet) internal _deployerFeeds;
    // quoteToken => deployer
    mapping(address => address) public quoteTokenToDeployer;

    event FeedSuggested(address indexed suggester, address indexed baseFeed);
    event FeedApproved(address indexed quoteToken, address indexed baseFeed);
    event FXPoolDeployerUpgraded(address indexed fxPoolDeployerNewImpl);

    function __FeedRegistry_init(address _chainLnkFeedRegistry, address _fxPoolDeployerImpl) internal initializer {
        require(_chainLnkFeedRegistry != address(0) && _fxPoolDeployerImpl != address(0), "Invalid address");

        chainLnkFeedRegistry = _chainLnkFeedRegistry;
        fxPoolDeployerImpl = _fxPoolDeployerImpl;

        _upgrader = new ProxyAdmin();
        __Ownable_init();
    }

    /**
     * @notice upgrade the fx pool deployer to a new implementation
     * @param _fxPoolDeployerNewImpl address of the new implementation
     * @param offset pagination start up place
     * @param limit size of the listing page
     */
    function upgradeFXPoolDeployers(address _fxPoolDeployerNewImpl, uint256 offset, uint256 limit) external onlyOwner {
        require(_fxPoolDeployerNewImpl != address(0), "Invalid address");

        require(Address.isContract(_fxPoolDeployerNewImpl), "Invalid address");

        if (_fxPoolDeployerNewImpl != fxPoolDeployerImpl) fxPoolDeployerImpl = _fxPoolDeployerNewImpl;

        uint256 to = (offset.add(limit)).min(_deployers.length()).max(offset);

        for (uint256 i = offset; i < to; i++) {
            _upgrader.upgrade(TransparentUpgradeableProxy(payable(_deployers.at(i))), _fxPoolDeployerNewImpl);
        }

        emit FXPoolDeployerUpgraded(_fxPoolDeployerNewImpl);
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
     * @param vault Balancer Vault address
     */
    function approveFeed(address baseFeed, address quoteToken, address vault) external onlyOwner {
        require(_isTokenValid(quoteToken), "Invalid address");

        require(vault != address(0), "Invalid address");

        require(_pendingFeeds.contains(baseFeed), "Feed does not exist");

        address _deployer = quoteTokenToDeployer[quoteToken];

        if (!_deployers.contains(_deployer)) {
            _deployer = _deployNewFXPoolDeployer(baseFeed, quoteToken, vault);

            _deployers.add(_deployer);

            quoteTokenToDeployer[quoteToken] = _deployer;
        }

        _pendingFeeds.remove(baseFeed);
        _approvedFeeds.add(baseFeed);

        _deployerFeeds[_deployer].add(baseFeed);

        // call adminApproveBaseOracle on deployer
        bytes memory data = abi.encodePacked(
            bytes4(keccak256("adminApproveBaseOracle(address)")),
            abi.encode(baseFeed)
        );
        _callDeployer(_deployer, data);

        emit FeedApproved(quoteToken, baseFeed);
    }

    /**
     * @notice list the registered deployers
     * @param offset pagination start up place
     * @param limit size of the listing page
     * @return _deployerArr array of deployer addresses
     */
    function listDeployers(uint256 offset, uint256 limit) external view returns (address[] memory _deployerArr) {
        uint256 to = (offset.add(limit)).min(_deployers.length()).max(offset);

        _deployerArr = new address[](to - offset);

        for (uint256 i = offset; i < to; i++) {
            _deployerArr[i - offset] = _deployers.at(i);
        }
    }

    /**
     * @notice Returns number of registered deployers
     */
    function countDeployers() external view returns (uint256) {
        return _deployers.length();
    }

    /**
     * @notice list the registered feeds (approved/pending)
     * @param approved true => get approved feeds, false => get pending feeds
     * @param offset pagination start up place
     * @param limit size of the listing page
     * @return _feedArr array of feed addresses
     */
    function listFeeds(bool approved, uint256 offset, uint256 limit) external view returns (address[] memory _feedArr) {
        EnumerableSet.AddressSet storage _set = approved ? _approvedFeeds : _pendingFeeds;

        uint256 to = (offset.add(limit)).min(_set.length()).max(offset);

        _feedArr = new address[](to - offset);

        for (uint256 i = offset; i < to; i++) {
            _feedArr[i - offset] = _set.at(i);
        }
    }

    /**
     * @notice Returns number of registered feeds (approved/pending)
     * @param approved true => get approved feeds count, false => get pending feeds count
     */
    function countFeeds(bool approved) external view returns (uint256) {
        return approved ? _approvedFeeds.length() : _pendingFeeds.length();
    }

    /**
     * @notice get approved feeds by quote token
     * @param quoteToken address of the quoteToken
     * @return _deployerFeedsArr array of feed addresses
     */
    function getFeedsByQuoteToken(address quoteToken) external view returns (address[] memory _deployerFeedsArr) {
        address _deployer = quoteTokenToDeployer[quoteToken];
        return _getFeedByDeployer(_deployer);
    }

    /**
     * @notice get approved feeds by deployer
     * @param deployer address of the fx pool deployer
     * @return _deployerFeedsArr array of feed addresses
     */
    function getFeedsByDeployer(address deployer) external view returns (address[] memory _deployerFeedsArr) {
        return _getFeedByDeployer(deployer);
    }

    /**
     * @notice Checks if a feed is approved
     * @param baseFeed The address of the feed
     * @return bool True if the feed is approved
     */
    function isFeedApproved(address baseFeed) external view returns (bool) {
        return _approvedFeeds.contains(baseFeed);
    }

    function _deployNewFXPoolDeployer(
        address baseFeed,
        address quoteToken,
        address vault
    ) internal returns (address _deployer) {
        BaseToUsdAssimilator _baseAssimilatorTemplate = new BaseToUsdAssimilator();

        UsdcToUsdAssimilator _quoteAssimilator = new UsdcToUsdAssimilator();

        _quoteAssimilator.initialize(IOracle(baseFeed), IERC20(quoteToken));

        // deploy a new proxy of fx pool deployer
        TransparentUpgradeableProxy _fxPoolDeployerProxy = new TransparentUpgradeableProxy(
            fxPoolDeployerImpl,
            address(_upgrader),
            ""
        );
        _deployer = address(_fxPoolDeployerProxy);
        // initialize  the proxy contract
        IFXPoolDeployer(_deployer).initialize(
            vault,
            quoteToken,
            address(_quoteAssimilator),
            address(_baseAssimilatorTemplate)
        );

        // call FXPoolDeployerTracker.broadcastNewDeployer()
    }

    /// @dev helper function to call a function on a deployer
    function _callDeployer(address deployer, bytes memory data) internal {
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

    function _isTokenValid(address tokenAddress) internal view returns (bool) {
        if (tokenAddress == address(0)) return false;
        try IERC20(tokenAddress).totalSupply() returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    function _isFeedValid(address feedAddress) internal view returns (bool) {
        if (feedAddress == address(0)) return false;
        return IFeedRegistry(chainLnkFeedRegistry).isFeedEnabled(feedAddress);
    }

    function _getFeedByDeployer(address deployer) internal view returns (address[] memory _deployerFeedsArr) {
        uint256 _deployerFeedsLength = _deployerFeeds[deployer].length();

        _deployerFeedsArr = new address[](_deployerFeedsLength);

        for (uint256 i = 0; i < _deployerFeedsLength; i++) {
            _deployerFeedsArr[i] = _deployerFeeds[deployer].at(i);
        }
    }
}

interface IFeedRegistry {
    function isFeedEnabled(address aggregator) external view returns (bool);
}

interface IFXPoolDeployer {
    function initialize(
        address _vault,
        address _quoteToken,
        address _quoteAssimilator,
        address _baseAssimilatorTemplate
    ) external;
}

interface FXPoolDeployerTracker {
    function broadcastNewDeployer(address _quoteToken, address _deployer) external returns (bytes32 key);
}
