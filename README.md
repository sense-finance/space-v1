# Space v1 • [![ci](https://github.com/sense-finance/space-v1/actions/workflows/ci.yml/badge.svg)](https://github.com/sense-finance/space-v1/actions/workflows/ci.yml) [![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)

This repo contains an implementation of [Sense Space](https://medium.com/sensefinance/introducing-sense-space-85a949087209), a YieldSpace implementation with a native yield-bearing side and an oracle, on top of Balancer v2. 

High-level notes and user journeys are available in the Sense docs [here](https://docs.sense.finance/docs/core-concepts/#sense-space). Also, note that while the Sense protocol utilizes Space, only the Space Factory contains logic tying the two together. One could easily make another factory independent of Sense.

## Deployments

### Space v1 Factory Contract Addresses

## Development

This repo uses [Foundry: forge](https://github.com/gakonst/foundry) for development and testing
and git submodules for dependency management.

To install Foundry [Foundry: Forge](https://github.com/gakonst/foundry), use the instructions in the linked repo.

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
