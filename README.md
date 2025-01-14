# BurrBear Oracle Registry

Each Burr Pool requires 2 oracles, a base token oracle and a quote token oracle.
For example, for the [NECT/HONEY](https://bartio.beratrail.io/address/0x39fca0a506d01ff9cb727fe8edf088e10f6b431a) pool, we have a NECT/USD and a HONEY/USD oracle.

The Oracle Registry serves 2 purposes:

- It acts as a registry of curated oracles that can be used to deploy new BurrPools permissionlessly
- It allows new projects to suggest new base token oracles to be whitelisted

## Proposing a new oracle for a token

To have an oracle approved by the registry, call the `suggestFeed` function:

```solidity
function suggestFeed(
    address quoteToken,     // The quote token (e.g., HONEY) that this feed will be used with
    address feedAddress,    // The address of the Chainlink-compatible price feed
    address[] calldata baseTokens // One or more base tokens that will use this feed
) external
```

For example, if you want to deploy a `NECT/HONEY` Burr Pool, you would first suggest the NECT/USD feed:

```solidity
address honey = 0x0E4aaF1351de4c0264C5c7056Ef3777b41BD8e03;
address nectFeed = 0x...; // The NECT/USD chainlink-compatible feed
address[] memory baseTokens = new address[](1);
baseTokens[0] = 0xf5AFCF50006944d17226978e594D4D25f4f92B40; // NECT token address
registry.suggestFeed(honey, nectFeed, baseTokens);
```

Note: The feed must be approved by the registry owner before it can be used.

### Suggesting a new base token for an existing oracle

If an oracle feed is already approved and you want to use it for another base token, you can call the `suggestBaseToken` function:

```solidity
function suggestBaseToken(
    address quoteToken, // The quote token (e.g., HONEY)
    address baseFeed,   // The already approved oracle feed address
    address baseToken   // The new base token to associate with this feed
) external
```

## Feed requirements

A feed must meet the following requirements to be approved:

1. Its code must be verified (on etherscan or equivalent block explorer)
2. It must implement the [AggregatorV3Interface](./src/interfaces/AggregatorV3Interface.sol) interface and successfully return data via `latestRoundData()`
3. It must be decentralized: there should be no permissioned actions or actors that can alter the value of the price feed
4. The feed must not be pausable or cancellable
5. If its data comes from a decentralized protocol, it must use a TWAP source rather than spot price
6. Both the feed address and any associated base tokens must be valid addresses (non-zero)
7. All base tokens must implement the ERC20 interface

## Deployed feeds

| Chain            | Feed Registry Address                                                                                                        |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Berachain bArtio | [0x952c430dCC00f623708d1CbBECe3A6f5741b1384](https://bartio.beratrail.io/address/0x952c430dCC00f623708d1CbBECe3A6f5741b1384) |

## Setup

```bash
forge soldeer install
forge build
```

## Q&A

Q: Why not allow BurrPools to be deployed with any base token oracles?

A: Unlike standard AMMs that don't require oracles, a BurrPool can be compromised if the oracle feed is manipulated to reflect an incorrect price for the token. Therefore, we only whitelist oracle aggregator contracts that are decentralized and resilient to such attacks.

Have questions? Reach us on Discord: https://discord.gg/zZh57URFCu
