## Cross-language ABI closure

After a fresh `forge build`, run:

```bash
python3 script/check_offchain_abi.py --self-test
python3 script/check_offchain_abi.py --artifacts out
```

The checker parses the first-party interfaces consumed by
`offchain-rust/src/abi.rs` and compares function inputs/outputs, mutability,
event indexing, anonymity, and tuple components with current Foundry artifacts.
CI runs both commands; selector-only checks are not sufficient because return
and indexed-field drift do not change selectors or event signature hashes.

## Sepolia source publication closure

The canonical staging manifest points to a self-contained copy of the exact
Solidity sources used for deployment. Verify every file hash, byte count, and
the aggregate source root with:

```bash
python3 script/check_sepolia_source_freeze.py
```

CI runs this check. It does not compare the deployment against the moving
`src/` tree; later source edits are expected and must not rewrite historical
deployment evidence.

## Deployment configuration

Both deployment scripts select [`config/DeploymentConfig.sol`](config/DeploymentConfig.sol) from `block.chainid`:

- Ethereum mainnet (`1`) uses the reviewed addresses committed in the config.
- Ethereum Sepolia (`11155111`) uses Circle's canonical test USDC at `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`, USD8Booster at `0xC0012770848FCD350AB11906e93ba9fdfDA19f4c`, and the explicit Sepolia environment addresses below.
- Every other chain reverts with `UnsupportedChain`.
- Zero-valued configuration entries revert with `MissingAddress`; before broadcasting, every dependency must contain contract code and pass reserve-decimal and live-oracle checks.

The Treasury proxy stores the selected six-decimal USDC once in ERC-7201 namespaced storage and exposes no reserve-asset setter; replacing the implementation cannot change it through constructor immutables.

## Launch scope

The system launches with:

- **one cover pool**: wstETH (the configured cover asset);
- **insured tokens**: USD8 only (80% max coverage); further insured tokens are added by governance after launch;
- **no Treasury yield strategies**: reserve USDC stays idle until governance adds reviewed ERC-4626 strategies with `Treasury.addStrategy` (strategies derive USDC from their owning Treasury and reject vaults whose `asset()` differs);
- **no sUSD8**: the savings vault is launched after deployment. `Registry.setSavingsVault` and `Registry.setScoredToken` are timelock-only, so sUSD8 registration and scoring go through a 24-hour governance proposal.

## Funds to prepare

The broadcasting account needs:

- native ETH on the selected network for deployment gas;
- 0.001 of the configured cover asset (wstETH on mainnet, `COVER_POOL_SEED`) to permanently seed the cover pool; and
- a signer supported by Foundry (keystore, hardware wallet, or another secure signer). Do not put a raw private key in this repository.

For Sepolia, obtain gas from an Ethereum Sepolia faucet; the cover asset is the admin-controlled mock configured in `SEPOLIA_COVER_ASSET`.

## Sepolia address configuration

USD8's complete external dependency set does not have one canonical Sepolia deployment. Deploy or select test contracts that implement the production interfaces, then set all of these before simulation:

```bash
export SEPOLIA_COVER_ASSET=0x...
export SEPOLIA_COVER_ASSET_USD_ORACLE=0x...
export SEPOLIA_USDC_USD_ORACLE=0x...
```

Requirements:

- price oracles must implement the Chainlink AggregatorV3 interface;
- the cover asset, booster and feeds must contain code on Sepolia;
- The governance admin (proposer/canceller and beta admin) is the mainnet admin `0xB2E999D531D45a9115dA7706adFc651999f3c1F1` on Sepolia too; it is hardcoded in `DeploymentConfig.sol`, not read from the environment.

Do not substitute ETH/USD for a wstETH/USD feed or reuse unrelated token addresses merely to make preflight pass.

### USD8 Sepolia staging package

The prepared public staging deployment uses the canonical Sepolia USDC plus the deployed USD8Booster. Dependencies without compatible canonical Sepolia deployments are explicit admin-controlled mocks from [`testnet/SepoliaDependencies.sol`](testnet/SepoliaDependencies.sol). They are suitable for signer, governance, frontend, indexing and claims workflow tests, but they are not evidence of production Aave, Sky, Lido or Chainlink integration; retain mainnet-fork coverage for those integrations.

The tracked [`deployment.json`](../deployments/sepolia/deployment.json) is the
canonical public staging record. Its referenced source freeze and public
receipt/journal artifacts are publication evidence. Generated transaction
plans, progress state, local configuration, and signer material remain ignored
operator state and must not be committed.

Run the read-only topology and funding verifier against the canonical manifest:

```bash
source deployments/sepolia/config.env
forge script script/testnet/VerifySepolia.s.sol:VerifySepolia --rpc-url "$RPC_URL"
```

## Mainnet preconditions

- Re-review every committed address and parameter in `DeploymentConfig.sol`.
- The configured booster, cover asset and feeds must contain the expected mainnet code.

## Governance requirements

Deployment is split so that initial setup can happen without a 24-hour delay:

1. **Step 01 (`01_DeployUSD8System.s.sol`)** deploys and wires the system. **No timelock is installed.** The deployer stays the Registry timelock, a Registry admin and the pool-beacon owner, and the configured admin is granted Registry admin. Timelock-only setup (`DefiInsurance.editInsuredToken`, `Registry.addPool`, `Registry.setScoredToken`, `Registry.setSavingsVault`, ...) can be done immediately from the deployer.
2. **Step 02 (`02_DeployTimelockAndHandOff.s.sol`)** deploys (or reuses, if already at its CREATE3 address) a timelock with:
   - 24-hour minimum delay;
   - the network-configured admin as sole proposer and canceller;
   - open execution (`address(0)` executor);
   - the timelock as its own admin, with no external admin.

   It rejects any other delay or role layout, requires the broadcaster to still hold the interim Registry-timelock and beacon-owner roles (so it cannot run twice or against another deployment), then transfers beacon ownership, grants the configured admin, drops the deployer as admin only if it is not the configured admin, and calls the irreversible `Registry.setTimelock` last.

**Between step 01 and step 02 the deployer can upgrade every proxy and the pool beacon without delay.** Do not open the system to users or describe it as timelocked until step 02 has run.

## Deterministic cross-chain addresses (CREATE3)

Both deployment scripts create every contract through [CreateX](https://github.com/pcaversaccio/createx) `deployCreate3` at its canonical address `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed` (see `script/lib/Create3Deployer.sol`). A contract's address depends only on:

1. the CreateX address,
2. the broadcasting deployer address, and
3. the contract's fixed label (the `LABEL_*` constants, e.g. `usd8.v1.USD8.proxy`).

It does **not** depend on constructor arguments, initializer calldata, nonces or the chain id. The same deployer therefore gets the same Timelock, Registry, USD8, Treasury, pool, DefiInsurance, oracle, strategy and bootstrap addresses on every chain, even though USDC, feeds and vaults differ.

Salts are deployer-guarded (first 20 bytes = deployer, byte 21 = `0x00`): CreateX only maps a salt to our address when the deployer itself submits it, so nobody can pre-deploy at our addresses on a new chain. Byte 21 is deliberately `0x00`: `0x01` would mix in the chain id and break cross-chain parity.

Rules:

- **Use the same deployer key on every chain.** A different key gives a completely different address set. Keep that key dedicated to USD8 deployments.
- **Never rename a label or reuse it for a different contract.** Bump the version segment (`v1` → `v2`) for an intentional fresh deployment; redeploying an existing label reverts with `Create3AddressOccupied`.
- **Verify CreateX exists on the target chain before deploying.** The scripts revert with `CreateXMissing` if there is no code at `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`. CreateX is deployed on most major EVM chains (Ethereum, Sepolia, Base, Arbitrum, Optimism, Polygon and many more). Check with `cast code 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed --rpc-url "$RPC_URL"`. On a chain without it, have CreateX deployed first by following the CreateX repository's new-chain deployment instructions (it must land at the same address).
- Predict any address before deploying:

  ```bash
  forge script script/01_DeployUSD8System.s.sol:DeployUSD8SystemScript \
    --sig "predictedAddress(address,string)" "$DEPLOYER" usd8.v1.USD8.proxy --rpc-url "$RPC_URL"
  ```

- sUSD8 is not part of the launch deployment. When it is launched later, its Morpho Vault V2 is created by Morpho's own `VaultV2Factory` (CREATE2, not CreateX), and Morpho's factory does not guard salts by sender, so audit finding C-1 (vault-address squatting) still applies to that later step.
- Constructors run inside CreateX's CREATE3 proxy, so `msg.sender` during construction is not the deployer. Any contract that needs an owner must take it as an explicit constructor argument (as `USD8SavingsBootstrap` now does).

## Preflight

```bash
forge build
forge test --match-path test/DeploymentConfig.t.sol
forge test --match-path test/DeployScript.t.sol
```

Set the RPC for the selected chain:

```bash
export RPC_URL=https://...
export ETHERSCAN_API_KEY=... # only for verification
```

Run both scripts once without `--broadcast`. Review every transaction, resolved address and gas estimate. Require a gas margin; do not rely on a fixed ETH estimate. Confirm the simulated addresses match `predictedAddress` for the intended deployer.

## Deploy

```bash
# Step 1: deploy, seed and wire the system (deployer keeps interim governance).
forge script script/01_DeployUSD8System.s.sol:DeployUSD8SystemScript \
  --rpc-url "$RPC_URL" --broadcast --slow --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY"

# ... initial admin setup from the deployer (extra insured tokens, pools, ...) ...

# Step 2: deploy the timelock and hand off governance (same deployer as step 1).
forge script script/02_DeployTimelockAndHandOff.s.sol:DeployTimelockAndHandOffScript \
  --rpc-url "$RPC_URL" --broadcast --slow --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY"
```

Use the same commands without `--broadcast` for simulation. Add the signer option appropriate for the configured Foundry account, and always pass `--sender <deployer>` so simulation uses the real deployer: both steps derive every CREATE3 address from it, and step 02 must be sent by the account holding interim governance.

**Always broadcast with `--slow`.** Without it Foundry submits transactions in parallel batches, so a failed transaction does not stop later ones: one-shot setters (`setUsd8`, `setTreasury`, `setSavingsVault`, `setBoosterConfig`) and the irreversible `setTimelock` hand-off can land on top of a broken state. With `--slow`, each transaction must be mined and succeed before the next is sent, and a failure halts the run. Where available, submit through a private / protected RPC to reduce front-running exposure during the sequence.

## Failure and recovery

Foundry broadcasts multiple transactions; the complete deployment is not atomic. If deployment succeeds partially or verification is interrupted, preserve the broadcast artifacts and use `--resume`. Do not blindly rerun deployment because deployed contracts and the permanent seed transfer are not rolled back.

After step 01, verify the Registry timelock and beacon owner are the deployer. After step 02, verify logged addresses, timelock roles and delay, Registry timelock/admin state, Treasury USDC, beacon ownership, canonical Registry pointers, cover-pool seed balance, USD8 scoring, insured tokens (USD8 only), the single wstETH pool and its feed, an empty strategy list, an unset savings vault, and profit receivers.
