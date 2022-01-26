# Sense Space v1

Implementation of [Sense Space](https://medium.com/sensefinance/introducing-sense-space-85a949087209) on top of Balancer v2. See the [Sense docs](https://docs.sense.finance/smart-contracts/space/) for high-level notes and user journeys.

## Development

Install Foundry [Foundry: Forge](https://github.com/gakonst/foundry) using the instructions in the README in the linked repo if you don't already have it.

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
yarn

# Run linter
yarn lint

# Run formatter
yarn fix
```

### Deploy


```bash
# Deploy a SpaceFactory
forge create SpaceFactory --constructor-args \
    <balancer_vault> <sense_divider> <timeshift> <fee_zero_in> <fee_zero_out> \
    --rpc-url <url> --private-key <key>
```