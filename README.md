# Space v1 • [![ci](https://github.com/sense-finance/space-v1/actions/workflows/ci.yml/badge.svg)](https://github.com/sense-finance/space-v1/actions/workflows/ci.yml) [![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)

This repo contains an implementation of [Sense Space](https://medium.com/sensefinance/introducing-sense-space-85a949087209), a YieldSpace implementation with a native yield-bearing side and an oracle, on top of Balancer v2. 

High-level notes and user journeys are available in the Sense docs [here](https://docs.sense.finance/docs/core-concepts/#sense-space). Also, note that while the Sense protocol utilizes Space, only the Space Factory contains logic tying the two together. One could easily make another factory independent of Sense.

## Deployments

### Space v1 Factory Contract Addresses

| Chain   | Address                                                                                                                                        |
| ------- | ------------------------------------------------------------------------------------------------------------------------- |
| Mainnet | [0x6633c65e9f80c65d98abde3f9f4e6e504f4d5352](https://etherscan.io/address/0x6633c65e9f80c65d98abde3f9f4e6e504f4d5352#code)                     |
| Goerli  | [0xfa1779ed7B384879D36d628564913f141ed930C4](https://kovan.etherscan.io/address/0xfa1779ed7B384879D36d628564913f141ed930C4#code)      

## Development

This repo uses [Foundry: forge](https://github.com/gakonst/foundry) for development and testing
and git submodules for dependency management.

To install Foundry, use the instructions in the linked repo.

### Test

```bash
# Get contract dependencies
git submodule update --init --recursive

# Run tests
forge test

# Run tests with tracing enabled
forge test -vvv
```

### Format

```bash
# Get node dependencies
yarn install # or npm install

# Run linter
yarn lint

# Run formatter
yarn fix
```

### Deploy


```bash
# Deploy a SpaceFactory
forge create SpaceFactory --constructor-args \
    <balancer_vault> <sense_divider> <timeshift> <fee_pts_in> <fee_pts_out> <oracle_enabled> \
    --rpc-url <url> --private-key <key>
```
