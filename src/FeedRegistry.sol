// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/AggregatorV3Interface.sol";

error DeployerAlreadyExists();
error QuoteTokenAlreadyExists();
error QuoteTokenMismatch();
error DeployerNotFound();
error FeedAlreadyExists();
error InvalidAddress();
error TokenAlreadyAssociated();
error FeedNotApproved();
error FeedDoesNotExist();
error CallToDeployerFailed();

/**
 * @title FeedRegistry
 * @notice A registry for Chainlink price feeds with associated ERC20 base tokens and FXPoolDeployer integration
 */
contract FeedRegistry is AccessControlUpgradeable, OwnableUpgradeable {
    struct Feed {
        address deployerAddress;
        address feedAddress;
        bool isApproved;
        address[] baseTokens;
    }

    struct PendingBaseToken {
        address quoteToken;
        address baseFeed;
        address baseToken;
    }

    // list of deployer addresses
    address[] private _deployers;
    address[] private _quoteTokens;
    // Mapping to store all feeds
    // deployer => baseFeed => Feed
    mapping(address => mapping(address => Feed)) private _feeds;
    // deployer => baseFeed[]
    mapping(address => Feed[]) private _feedsList;

    // map deployer to quote token
    mapping(address => address) public deployerToQuoteToken;
    // map quote token to deployer
    mapping(address => address) public quoteTokenToDeployer;

    // list of pending feeds
    Feed[] public feedsPending;
    // list of pending base tokens
    PendingBaseToken[] public pendingBaseTokens;

    event FeedApproved(address indexed quoteToken, address indexed baseFeed);
    event BaseTokenAdded(
        address indexed quoteToken,
        address indexed baseFeed,
        address indexed baseToken
    );
    event BaseTokenRemoved(
        address indexed quoteToken,
        address indexed baseFeed,
        address indexed baseToken
    );
    event FeedSuggested(
        address indexed suggester,
        address indexed quoteToken,
        address indexed baseFeed,
        address[] tokens
    );
    event BaseTokenSuggested(
        address indexed suggester,
        address indexed quoteToken,
        address indexed baseFeed,
        address baseToken
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // see Initializable.sol: To prevent the implementation contract
        // from being used, you should invoke the {_disableInitializers} function
        // in the constructor to automatically lock it when it is deployed
        _disableInitializers();
    }

    function initialize(address initialOwner) public initializer {
        __Ownable_init(initialOwner);
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }

    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }

    function addDeployer(
        address quoteToken,
        address deployer
    ) external onlyOwner {
        _validToken(quoteToken);
        if (deployer == address(0)) revert InvalidAddress();
        if (quoteToken == address(0)) revert InvalidAddress();
        if (deployerToQuoteToken[deployer] != address(0))
            revert DeployerAlreadyExists();
        if (quoteTokenToDeployer[quoteToken] != address(0))
            revert QuoteTokenAlreadyExists();
        if (IHasQuoteToken(deployer).quoteToken() != quoteToken)
            revert QuoteTokenMismatch();

        _deployers.push(deployer);
        _quoteTokens.push(quoteToken);
        deployerToQuoteToken[deployer] = quoteToken;
        quoteTokenToDeployer[quoteToken] = deployer;
    }

    function removeDeployer(address deployer) external onlyOwner {
        address quoteToken = deployerToQuoteToken[deployer];
        delete quoteTokenToDeployer[quoteToken];
        delete deployerToQuoteToken[deployer];
        uint256 len = _deployers.length;
        for (uint256 i = 0; i < len; i++) {
            if (_deployers[i] == deployer) {
                _deployers[i] = _deployers[len - 1];
                _deployers.pop();
                break;
            }
        }
        len = _quoteTokens.length;
        for (uint256 i = 0; i < len; i++) {
            if (_quoteTokens[i] == quoteToken) {
                _quoteTokens[i] = _quoteTokens[len - 1];
                _quoteTokens.pop();
                break;
            }
        }
    }

    /**
     * @notice Suggests a new feed to be added to the registry along with associated base tokens
     * @param quoteToken The address of the quote token
     * @param feedAddress The address of the Chainlink price feed
     * @param baseTokens Array of ERC20 base token addresses to associate with the feed
     */
    function suggestFeed(
        address quoteToken,
        address feedAddress,
        address[] calldata baseTokens
    ) external {
        address deployer = quoteTokenToDeployer[quoteToken];
        if (deployer == address(0)) revert DeployerNotFound();
        _validFeed(feedAddress);
        if (_feeds[deployer][feedAddress].deployerAddress != address(0))
            revert FeedAlreadyExists();

        // Verify that the address implements AggregatorV3Interface
        AggregatorV3Interface feed = AggregatorV3Interface(feedAddress);
        feed.latestRoundData(); // Will revert if not a valid feed

        // Verify all token addresses implement IERC20
        for (uint256 i = 0; i < baseTokens.length; i++) {
            if (baseTokens[i] == address(0)) revert InvalidAddress();
            IERC20(baseTokens[i]).totalSupply(); // Will revert if not a valid ERC20
        }

        // Store pending tokens
        feedsPending.push(
            Feed({
                feedAddress: feedAddress,
                deployerAddress: deployer,
                isApproved: false,
                baseTokens: baseTokens
            })
        );

        emit FeedSuggested(msg.sender, quoteToken, feedAddress, baseTokens);
    }

    /**
     * @notice Approves a pending feed and its associated base tokens
     * @param _pendingIndex The index of the feed to approve
     */
    function approveFeed(uint256 _pendingIndex) external onlyOwner {
        if (_pendingIndex >= feedsPending.length) revert FeedDoesNotExist();

        Feed memory pendingFeed = feedsPending[_pendingIndex];
        address baseFeed = pendingFeed.feedAddress;
        if (baseFeed == address(0)) revert FeedDoesNotExist();
        pendingFeed.isApproved = true;

        address deployer = pendingFeed.deployerAddress;
        address quoteToken = deployerToQuoteToken[deployer];

        _feeds[deployer][baseFeed] = pendingFeed;
        _feedsList[deployer].push(pendingFeed);

        // call adminApproveBaseOracle on deployer
        bytes memory data = abi.encodePacked(
            bytes4(keccak256("adminApproveBaseOracle(address)")),
            abi.encode(baseFeed)
        );
        _callDeployer(deployer, data);

        // Clean up pending tokens storage
        delete feedsPending[_pendingIndex];

        emit FeedApproved(quoteToken, baseFeed);
        uint256 len = pendingFeed.baseTokens.length;
        for (uint256 i = 0; i < len; i++) {
            emit BaseTokenAdded(
                quoteToken,
                baseFeed,
                pendingFeed.baseTokens[i]
            );
        }
    }

    function removeFeed(
        address quoteToken,
        address baseFeed
    ) external onlyOwner {
        address deployer = quoteTokenToDeployer[quoteToken];
        if (deployer == address(0)) revert DeployerNotFound();

        Feed memory feed = _feeds[deployer][baseFeed];
        if (!feed.isApproved) revert FeedNotApproved();
        delete _feeds[deployer][baseFeed];

        // call adminDisapproveBaseOracle on deployer
        bytes memory data = abi.encodePacked(
            bytes4(keccak256("adminDisapproveBaseOracle(address)")),
            abi.encode(baseFeed)
        );
        _callDeployer(deployer, data);

        Feed[] storage feedList = _feedsList[deployer];
        uint256 len = feedList.length;
        for (uint256 i = 0; i < len; i++) {
            if (feedList[i].feedAddress == baseFeed) {
                feedList[i] = feedList[len - 1];
                feedList.pop();
                break;
            }
        }
    }

    /**
     * @notice Suggests a new base token for an approved feed
     * @param quoteToken The address of the quote token
     * @param baseFeed The address of the approved feed
     * @param baseToken The address of the ERC20 base token to associate
     */
    function suggestBaseToken(
        address quoteToken,
        address baseFeed,
        address baseToken
    ) external {
        _validToken(baseToken);
        address deployer = quoteTokenToDeployer[quoteToken];
        if (deployer == address(0)) revert DeployerNotFound();

        Feed memory feed = _feeds[deployer][baseFeed];
        if (!feed.isApproved) revert FeedNotApproved();

        // ensure token is not already associated
        for (uint256 i = 0; i < feed.baseTokens.length; i++) {
            if (feed.baseTokens[i] == baseToken)
                revert TokenAlreadyAssociated();
        }

        pendingBaseTokens.push(
            PendingBaseToken({
                quoteToken: quoteToken,
                baseFeed: baseFeed,
                baseToken: baseToken
            })
        );

        emit BaseTokenSuggested(msg.sender, quoteToken, baseFeed, baseToken);
    }

    /**
     * @notice Approves a pending base token
     * @param _pendingIndex The index of the base token to approve
     */
    function approveBaseToken(uint256 _pendingIndex) external onlyOwner {
        if (_pendingIndex >= pendingBaseTokens.length)
            revert FeedDoesNotExist();

        PendingBaseToken memory pending = pendingBaseTokens[_pendingIndex];
        _validToken(pending.baseToken);
        address deployer = quoteTokenToDeployer[pending.quoteToken];

        if (!_feeds[deployer][pending.baseFeed].isApproved)
            revert FeedNotApproved();

        // Add the token to the feed's associated tokens
        _feeds[deployer][pending.baseFeed].baseTokens.push(pending.baseToken);

        // Clean up pending base token
        delete pendingBaseTokens[_pendingIndex];

        emit BaseTokenAdded(
            pending.quoteToken,
            pending.baseFeed,
            pending.baseToken
        );
    }

    function removeBaseToken(
        address quoteToken,
        address baseFeed,
        address baseToken
    ) external onlyOwner {
        address deployer = quoteTokenToDeployer[quoteToken];
        if (deployer == address(0)) revert DeployerNotFound();
        if (!_feeds[deployer][baseFeed].isApproved) revert FeedNotApproved();
        address[] storage tokens = _feeds[deployer][baseFeed].baseTokens;
        for (uint i = 0; i < tokens.length; i++) {
            if (tokens[i] == baseToken) {
                tokens[i] = tokens[tokens.length - 1];
                tokens.pop();
                break;
            }
        }

        emit BaseTokenRemoved(quoteToken, baseFeed, baseToken);
    }

    /**
     * @notice Allow owner to call functions on a deployer.
     * @dev This is useful for calling adminApproveBaseOracle and adminDisapproveBaseOracle
     * on the deployer contract but also for transferring ownership of the deployer
     * contract if ever needed.
     * @param deployer The address of the deployer
     * @param data The data to call the function with
     */
    function callDeployer(
        address deployer,
        bytes memory data
    ) external onlyOwner {
        _callDeployer(deployer, data);
    }

    /// @dev helper function to call a function on a deployer
    function _callDeployer(address deployer, bytes memory data) private {
        if (deployerToQuoteToken[deployer] == address(0))
            revert DeployerNotFound();

        (bool success, bytes memory returnData) = deployer.call(data);
        if (!success) {
            // If there is return data, try to extract and revert with the original error message
            if (returnData.length > 0) {
                assembly {
                    let returnDataSize := mload(returnData)
                    revert(add(32, returnData), returnDataSize)
                }
            } else {
                revert CallToDeployerFailed();
            }
        }
    }

    function _validFeed(address feedAddress) private view {
        if (feedAddress == address(0)) revert InvalidAddress();
        AggregatorV3Interface(feedAddress).latestRoundData();
    }

    function _validToken(address tokenAddress) private view {
        if (tokenAddress == address(0)) revert InvalidAddress();
        IERC20(tokenAddress).totalSupply(); // Will revert if not a valid ERC20
    }

    function getDeployers() external view returns (address[] memory) {
        return _deployers;
    }

    function getQuoteTokens() external view returns (address[] memory) {
        return _quoteTokens;
    }

    function getFeeds(address deployer) external view returns (Feed[] memory) {
        return _feedsList[deployer];
    }

    function getFeedByQuoteToken(
        address quoteToken,
        address baseFeed
    ) external view returns (Feed memory) {
        address deployer = quoteTokenToDeployer[quoteToken];
        if (deployer == address(0)) revert DeployerNotFound();
        return _feeds[deployer][baseFeed];
    }

    function getFeedByDeployer(
        address deployer,
        address baseFeed
    ) external view returns (Feed memory) {
        return _feeds[deployer][baseFeed];
    }
    /**
     * @notice Returns all base tokens for a feed
     * @param quoteToken The address of the quote token
     * @param baseFeed The address of the approved feed
     * @return tokens Array of base token addresses
     */
    function getBaseTokens(
        address quoteToken,
        address baseFeed
    ) external view returns (address[] memory) {
        address deployer = quoteTokenToDeployer[quoteToken];
        if (deployer == address(0)) revert DeployerNotFound();
        if (_feeds[deployer][baseFeed].feedAddress == address(0))
            revert FeedDoesNotExist();
        return _feeds[deployer][baseFeed].baseTokens;
    }

    /**
     * @notice Checks if a feed is approved
     * @param quoteToken The address of the quote token
     * @param baseFeed The address of the approved feed
     * @return bool True if the feed is approved
     */
    function isFeedApproved(
        address quoteToken,
        address baseFeed
    ) external view returns (bool) {
        address deployer = quoteTokenToDeployer[quoteToken];
        if (deployer == address(0)) revert DeployerNotFound();
        return _feeds[deployer][baseFeed].isApproved;
    }
}

interface IHasQuoteToken {
    function quoteToken() external view returns (address);
}
