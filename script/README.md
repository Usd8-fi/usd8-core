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
- Ethereum Sepolia (`11155111`) uses Circle's canonical test USDC at `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`, [Morpho's official](https://docs.morpho.org/developers/contracts/addresses) Vault V2 factory at `0xb3fE2D5f8Af90f194B01db546397058Fcebb85D1`, USD8Booster at `0xC0012770848FCD350AB11906e93ba9fdfDA19f4c`, and the explicit Sepolia environment addresses below.
- Every other chain reverts with `UnsupportedChain`.
- Zero-valued configuration entries revert with `MissingAddress`; before broadcasting, every dependency must contain contract code and pass reserve-decimal, Morpho-factory, vault-underlying, conversion, and live-oracle checks.

The Treasury proxy stores the selected six-decimal USDC once in ERC-7201 namespaced storage and exposes no reserve-asset setter; replacing the implementation cannot change it through constructor immutables. Strategies derive USDC from their owning Treasury and reject ERC-4626 vaults whose `asset()` differs.

## Funds to prepare

The broadcasting account needs:

- native ETH on the selected network for deployment gas;
- at least 10 units of the configured USDC to permanently seed sUSD8; and
- a signer supported by Foundry (keystore, hardware wallet, or another secure signer). Do not put a raw private key in this repository.

For Sepolia, obtain gas from an Ethereum Sepolia faucet and test USDC from <https://faucet.circle.com/>. Circle currently dispenses enough test USDC for the 10-USDC seed.

## Sepolia address configuration

USD8's complete external dependency set does not have one canonical Sepolia deployment. Deploy or select test contracts that implement the production interfaces, then set all of these before simulation:

```bash
export SEPOLIA_ADMIN=0x...
export SEPOLIA_COVER_ASSET=0x...
export SEPOLIA_COVER_ASSET_USD_ORACLE=0x...
export SEPOLIA_AAVE_USDC_VAULT=0x...
export SEPOLIA_MORPHO_USDC_VAULT=0x...
export SEPOLIA_AAVE_SGHO=0x...
export SEPOLIA_GHO_USD_ORACLE=0x...
export SEPOLIA_SKY_SUSDS=0x...
export SEPOLIA_USDS_USD_ORACLE=0x...
export SEPOLIA_USDC_USD_ORACLE=0x...
```

Requirements:

- both configured Treasury strategy vaults must be ERC-4626 and return Sepolia USDC from `asset()`;
- insured-token conversion contracts must support `convertToAssets(1e18)`;
- price oracles must implement the Chainlink AggregatorV3 interface;
- the Morpho address must be a compatible Vault V2 factory;
- the cover asset, booster, vaults, insured tokens and feeds must contain code on Sepolia;
- `SEPOLIA_ADMIN` must be the intended proposer/canceller and beta admin.

Do not substitute ETH/USD for a wstETH/USD feed or reuse unrelated token addresses merely to make preflight pass.

### USD8 Sepolia staging package

The prepared public staging deployment uses the canonical Sepolia USDC and Morpho Vault V2 factory plus the deployed USD8Booster. Dependencies without compatible canonical Sepolia deployments are explicit admin-controlled mocks from [`testnet/SepoliaDependencies.sol`](testnet/SepoliaDependencies.sol). They are suitable for signer, governance, frontend, indexing and claims workflow tests, but they are not evidence of production Aave, Sky, Lido or Chainlink integration; retain mainnet-fork coverage for those integrations.

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
- `aaveUsdcVault` remains explicitly marked for review/replacement before live deployment.
- The configured Morpho factory, booster, cover asset, feeds, insured tokens and strategy vaults must contain the expected mainnet code.
- Set `AAVE_STRATEGY_REVIEWED=true` only after reviewing the configured launch strategy and vault.

## Governance requirements

Step 01 creates a timelock with:

- 24-hour minimum delay;
- the network-configured admin as sole proposer and canceller;
- open execution (`address(0)` executor);
- the timelock as its own admin, with no external admin.

Step 02 rejects a timelock without that exact delay and role configuration. It performs bootstrap configuration using temporary deployer authority, then transfers Registry, vault and beacon authority to the validated governance accounts.

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
export AAVE_STRATEGY_REVIEWED=true
```

Run both scripts once without `--broadcast`. Review every transaction, resolved address and gas estimate. Require a gas margin; do not rely on a fixed ETH estimate.

## Deploy

```bash
# Step 1: deploy governance.
forge script script/01_DeployTimelock.s.sol:DeployTimelockScript \
  --rpc-url "$RPC_URL" --broadcast --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY"

# Copy the address printed by step 1.
export TIMELOCK_ADDRESS=0x...

# Step 2: deploy, seed, wire and hand off the system.
forge script script/02_DeployUSD8System.s.sol:DeployUSD8SystemScript \
  --sig "run(address)" "$TIMELOCK_ADDRESS" \
  --rpc-url "$RPC_URL" --broadcast --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY"
```

Use the same commands without `--broadcast` for simulation. Add the signer option appropriate for the configured Foundry account.

## Failure and recovery

Foundry broadcasts multiple transactions; the complete deployment is not atomic. If deployment succeeds partially or verification is interrupted, preserve the broadcast artifacts and use `--resume`. Do not blindly rerun deployment because deployed contracts and the permanent seed transfer are not rolled back.

Before accepting deployment, verify logged addresses, timelock roles and delay, Registry timelock/admin state, Treasury USDC, beacon ownership, canonical Registry pointers, sUSD8 seed balance, scoring, insured-token configuration, feeds, strategies and profit receivers.
