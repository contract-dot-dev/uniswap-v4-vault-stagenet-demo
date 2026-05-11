# Uniswap V4 Vault Stagenet Demo

This repo contains a demo Uniswap v4 LP vault that can be deployed to a [Stagenet](https://docs.contract.dev/stagenets) and used to demonstrate a production-grade DeFi testing workflow.

## How the vault works

The vault is an ERC20 whose shares represent pro-rata ownership of a single Uniswap v4 LP position. 

The vault deploys its own v4 pool keyed to USDC/WETH at the 0.05% fee tier and attaches a custom hook contract to it that drives ongoing maintenance.

Users interact with the vault by calling:

- `mint` — mints vault shares and adds liquidity to its position.
- `withdraw` — burns shares and returns a proportional amount of WETH and USDC from the vault’s position.

Two actions keep the position productive:

- `compound()` — claims the fees the position has earned and redeposits them as additional liquidity.
- `rebalance()` — closes the current position and opens a fresh one centred on the live tick.

Both can be invoked manually, but the attached **VaultHook** also runs them automatically on `afterSwap`:

- Every Nth swap against the pool triggers an auto-compound (cadence configurable via `setCompoundEvery`).
- Any swap whose post-trade tick falls outside the vault's current range triggers an auto-rebalance.

The hook itself never holds funds — it only pokes the vault, which then settles its own deltas with the PoolManager inside the same `unlock` context.

USD-denominated TVL and share price are derived from Chainlink price feeds and made available in view functions.

## Why deploy it on a Stagenet?

Uniswap v4 LP vaults depend on real DeFi conditions: pool price, liquidity, ticks, token balances, etc. They also depend on the canonical v4 PoolManager and supporting infrastructure being deployed at the same addresses as mainnet.

A Stagenet gives this vault a production-like environment to run in, with built-in tools to inspect and simulate how it behaves before mainnet.

With this demo, you can:

1. Deploy the vault on an Ethereum-replicating Stagenet, configured to use the canonical v4 PoolManager and the USDC/WETH 0.05% market reference price
2. Add liquidity to its pool position using tokens obtained from the Stagenet's faucet
3. Simulate periodic swaps using the Stagenet's activity simulator to generate fees and exercise the hook's auto-compound / auto-rebalance logic
4. Periodically compound and rebalance the position manually as well
5. Track and graph TVL, share price, earned fees, and hook trigger counts over time via the Stagenet's analytics
6. Inspect transactions, balances, state, and more in the vault's Workspace

## Quickstart

1. Create a project in [contract.dev](https://contract.dev).
   Each project includes a Stagenet: a private EVM testnet with built-in tools and analytics.

2. Import this GitHub repo from your Stagenet's **CI/CD** dashboard.
   It will compile the vault and prepare a Workspace for when it is deployed.

3. Generate a funded wallet using the Stagenet's [Wallet Generator](https://docs.contract.dev/stagenets/tools/wallet-generator).
   It gives you a private key and ETH for deployment gas in one step.

4. Deploy the vault to your Stagenet.

   ```bash
   export STAGENET_RPC_URL=<YOUR_STAGENET_RPC_URL>
   export PRIVATE_KEY=<YOUR_FUNDED_PRIVATE_KEY>

   # Option A: Deploy the hook + vault only. The pool is initialized but the
   # vault has no position yet.
   forge script script/Deploy.s.sol \
     --rpc-url $STAGENET_RPC_URL \
     --private-key $PRIVATE_KEY \
     --broadcast

   # Option B: Deploy and seed the vault with an opening position in one tx.
   # Requires the deployer wallet to hold USDC + WETH from the faucet.
   SHARES=500000000000000000000000 forge script script/DeployAndSeed.s.sol \
     --rpc-url $STAGENET_RPC_URL \
     --private-key $PRIVATE_KEY \
     --broadcast
   ```

5. Open the vault's new Workspace via your Stagenet's **Analytics** dashboard.

## Vault Interaction

Once deployed, set a `VAULT` env var to the deployed address and run any of the scripts in `./script`.
Send your wallet some USDC and WETH from the Stagenet's [Faucet](https://docs.contract.dev/stagenets/tools/faucet) if you plan to mint vault shares or run swaps.

```bash
export STAGENET_RPC_URL=<YOUR_STAGENET_RPC_URL>
export PRIVATE_KEY=<YOUR_FUNDED_PRIVATE_KEY>
export VAULT=<DEPLOYED_VAULT_ADDRESS>

# Mint shares and add liquidity to the vault's position
SHARES=50000000000000000 forge script script/Mint.s.sol \
  --rpc-url $STAGENET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast

# Swap against the vault's underlying pool via the canonical UniversalRouter
# (with Permit2 approvals) to move price and generate fees. Each swap also
# fires the vault's hook, which may auto-compound or auto-rebalance.
AMOUNT_IN=100000000 ZERO_FOR_ONE=true forge script script/Swap.s.sol \
  --rpc-url $STAGENET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast

# Manually claim fees and redeposit them as additional liquidity
forge script script/Compound.s.sol \
  --rpc-url $STAGENET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast

# Manually close the current position and re-open it around the live tick
forge script script/Rebalance.s.sol \
  --rpc-url $STAGENET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```
