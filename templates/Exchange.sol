// Proof of concept (not yet audited).
pragma solidity ^0.5.1;
pragma experimental ABIEncoderV2;
import './SafeMath.sol';
import './ECVerify.sol';


/***** Abbreviations ***
 * SV: SECURITY VULNERABILITY
 * NROS: No Room On Stack!
 * NGM: Rely on net gas metering for sstore optimization
 * SBE: Should be marked external but ABIEncoderV2 does not allow
          calldata structs
 * SBP: Should be pure but Solidity cannot detect no read
 * SBC: Should be constant but structs cannot be constant
 * JE: Journal entry. A set of debits combined with a set of balancing credits.
 * DR: The debit side of a journal entry
 * CR: The credit side of a journal entry
 * COO: Could optimize out
 * SOO: Should optimize out
 *****/

// No way to subclass, e.g. newtypes like interface BaseToken extends ERC20
interface ERC20 {
  function totalSupply() external view returns (uint supply);
  function balanceOf(address _owner) external view returns (uint balance);
  function transfer(address _to, uint _value) external returns (bool success);
  function transferFrom(address _from, address _to, uint _value) external returns (bool success);
  function approve(address _spender, uint _value) external returns (bool success);
  function allowance(address _owner, address _spender) external view returns (uint remaining);
  function decimals() external view returns(uint digits);
  event Approval(address indexed _owner, address indexed _spender, uint _value);
}

contract Main {
  using SafeMath for uint256;

  uint256 constant LOCKUP_PERIOD_SECONDS = 600; // 10 minutes
  uint256 forfeiture_fee_nonce = 0; // can this be memory?

  /* Maybe a way to corral all external calls to transition function
  struct JournalEntry {
    ERC20 asset;
    address from;
    address to;
    uint256 amount;
  }

  // Number of transfers per call is limited.
  function allocate_journal() returns (JournalEntry[] memory)
    private
  {
    return new JournalEntry[](16);
  }

  // Always call at end of function after internal state changes.
  function execute_journal(JournalEntry[] memory entries)
    private
  {
    for (entry in journal_entries) {
      if (entry.from == address(this)) {
        require(entry.asset.transfer(entry.to, entry.amount));
      } else {
        require(entry.asset.transferFrom(entry.from, entry.to, entry.amount));
      }
    }
  }
 */

  // where tokens go when they are burnt.
  // some sort of charity or insurance fund but 0x00 for POC.
  address constant BURN_FUND = address(0);

  ${def_struct eip712DomainTy}
  ${def_eip712StructTypeHash eip712DomainTy}

  // SBC
  function eip712DomainSeparator() public view returns (bytes32) {
    string memory ${ref_struct_member "eip712Domain" "name"} =
      "Beacon Exchange";
    string memory ${ref_struct_member "eip712Domain" "version"} =
      "v0.0.0";
    address ${ref_struct_member "eip712Domain" "verifyingContract"} =
      address(this);

    return keccak256(abi.encode(
      ${ref_eip712StructTypeHash eip712DomainTy},
      keccak256(bytes(${ref_struct_member "eip712Domain" "name"})),
      keccak256(bytes(${ref_struct_member "eip712Domain" "version"})),
      ${ref_struct_member "eip712Domain" "verifyingContract"}
    ));
  }

  /*** Off-chain structs ***/
  ${def_struct ittTy}
  ${def_eip712StructTypeHash ittTy}

  ${def_struct poiTy}
  ${def_eip712StructTypeHash poiTy}

  /*** Contract data structures ***/

  enum EscrowState {
    Invalid,
    OnDeposit,
    Withdrawing
  }

  // escrow balance must go through lockup process to withdraw to allow
  // for challenges.
  struct Escrow {
    EscrowState state; // COO this can probably be inferred by unencumbered_at
    uint256/*timestamp*/ unencumbered_at;
    bytes32 spent_proof; // non-null if proof of spend has been seen
    address beneficiary;
    uint256 amount;
    // Never accessed except for slashing in case of double spend proof
    // Can be inferred from amount.
    uint256 buffer_balance; // COO
  }

  struct Challenge {
    uint256/*timestamp*/ ends_at; // COO
    bytes32 escrow_id;
    address incumbent; // SOO should be part of key. Perhaps rename to maker
    address challenger; // SOO should be part of key. Perhaps rename to taker
    uint256 base_amount;
    uint256 dst_amount;
    bool forfeited; // COO: could compress this into ends_at
  }

  struct Deposit {
    uint256 deposit_balance;
  }


  mapping(address/*token*/ =>
          mapping(address/*user*/ =>
                  mapping(bytes32/*ID*/ =>
                          Escrow))) escrows;

  mapping(address/*token*/ =>
          mapping(address/*user*/ =>
                  Deposit)) deposits;

  // COO Only used to clarify balance sheet invariants
  mapping(address/*token*/ =>
          uint256) balances;

  mapping(address/*base*/ =>
          mapping(address/*dst*/ =>
                  mapping(bytes32/*itt hash*/ =>
                          Challenge))) challenges;


  function() external {
    revert();
  }


  function _expired(uint256 timestamp) private view returns (bool) {
    return timestamp < block.timestamp;
  }


  function min(uint256 x, uint256 y)
    private
    pure
    returns (uint256)
  {
    return x < y ? x : y;
  }

  // EIP712 encoding
  function eip712encode(bytes32 structDigest)
    private
    view
    returns (bytes32)
  {
    return keccak256(abi.encodePacked(
      "\x19\x01",
      eip712DomainSeparator(),
      structDigest));
  }


  function _lookup_deposit(ERC20 tok, address sender)
    private
    view // SBP
    returns (Deposit storage)
  {
    return deposits[address(tok)][sender];
  }

  function _lookup_challenge(ERC20 base, ERC20 dst, bytes32 itt_hash)
    private
    view // SBP
    returns (Challenge storage)
  {
    return challenges[address(base)][address(dst)][itt_hash];
  }


  // single-entry functions!! must always have offsetting txn
  function _debit(ERC20 tok, address user, uint256 amount)
    private
  {
    if (user == address(this)) {
      // self balances are debit normal
      balances[address(tok)] = balances[address(tok)].add(amount);
    } else {
      Deposit storage d = _lookup_deposit(tok, user);
      // user deposits are credit normal
      d.deposit_balance = d.deposit_balance.sub(amount);
    }
  }
  function _credit(ERC20 tok, address user, uint256 amount)
    private
  {
    if (user == address(this)) {
      // self balances are debit normal
      balances[address(tok)] = balances[address(tok)].sub(amount);
    } else {
      Deposit storage d = _lookup_deposit(tok, user);
      // user deposits are credit normal
      d.deposit_balance = d.deposit_balance.add(amount);
    }
  }

  event Deposit_(ERC20 tok, address indexed owner, uint256 amount);
  function deposit(ERC20 tok, uint256 amount)
    external
  {
    // JE
    //   DR
    _debit(tok, address(this), amount);
    //   CR
    _credit(tok, msg.sender, amount);

    require(tok.transferFrom(msg.sender, address(this), amount),
            "Transfer failed");

    emit Deposit_(tok, msg.sender, amount);
  }

  event Withdraw(ERC20 tok, address indexed owner, uint256 amount);
  function withdraw(ERC20 tok, uint256 amount)
    external
  {
    // JE
    //   DR
    _debit(tok, msg.sender, amount);
    //   CR
    _credit(tok, address(this), amount);

    require(tok.transfer(msg.sender, amount),
            "Transfer failed");

    emit Withdraw(tok, msg.sender, amount);
  }

  function _lookup_escrow(ERC20 tok, address sender, bytes32 id)
    private
    view
    returns (Escrow storage)
  {
    return escrows[address(tok)][sender][id];
  }

  event DepositEscrow(ERC20 tok, address indexed sender, bytes32 id, uint256 amount);
  function deposit_forfeiture_fee(ERC20 tok, uint256 amount)
    external
    returns (bytes32 forfeiture_fee_id)
  {
    uint256 total_amount = amount.mul(2);

    // Technically there is possibility of overflow but it would be
    // practically impossible to generate enough function calls in a single
    // block to generate a collision.
    forfeiture_fee_nonce++; // Alternative: User-provided nonce?
    //   Could save gas but requires extra checks.

    bytes32 _blockhash = blockhash(block.number);
    bytes32 id = keccak256(abi.encodePacked(forfeiture_fee_nonce, _blockhash));

    Escrow storage escrow =
      _lookup_escrow(tok, msg.sender, id);

    // Check that our uuid generation worked.
    assert(escrow.state == EscrowState.Invalid);

    escrow.state = EscrowState.OnDeposit;
    escrow.unencumbered_at = uint256(-1);

    // JE
    assert(amount + escrow.buffer_balance == total_amount);
    //   DR
    _debit(tok, msg.sender, total_amount);
    //   CR
    escrow.amount = amount;
    // optimization opp: skip sstore and trust escrow_balance == buffer_balance
    escrow.buffer_balance = amount;

    emit DepositEscrow(tok, msg.sender, id, amount);
    return id;
  }


  event EscrowSlashed(ERC20 tok, address owner, bytes32 indexed id, address claimant, address prover);
  function _slash_escrow(ERC20 tok, address owner, bytes32 id, address claimant)
    private
  {
    Escrow storage escrow = _lookup_escrow(tok, owner, id);
    uint256 amount = escrow.amount;
    uint256 error_bit = amount % 2;
    // TODO assign error bit to burn fund
    // arbitrarily assign the error bit.
    // don't really need safemath here.
    uint256 claim1_amount = amount.div(2) + error_bit;
    uint256 claim2_amount = amount.div(2);

    // JE
    assert(claim1_amount + claim2_amount == amount);
    //   DR
    escrow.amount = 0; // redundant with later delete - NGM
    //   CR
    _credit(tok, escrow.beneficiary, claim1_amount);
    _credit(tok, claimant, claim2_amount);

    // JE
    assert(escrow.buffer_balance == amount);
    //   DR
    escrow.buffer_balance = 0; // redundant with later delete - NGM
    //   CR
    _credit(tok, BURN_FUND, amount);

    delete escrows[address(tok)][owner][id];

    emit EscrowSlashed(tok, owner, id, escrow.beneficiary, claimant);
  }

  event EscrowSpent(ERC20 tok, address owner, bytes32 indexed id, bytes32 spent_proof, address claimant); // add expiry?
  // If the escrow is already spent, slash it.
  // Returns true iff the escrow could be encumbered:
  //   1) the escrow is not expired, and
  //   2) the escrow does not already have a spent proof.
  function _supply_escrow_spend_proof(ERC20 tok, address owner, bytes32 id, uint256 unencumbered_at, address claimant, bytes32 spent_proof)
    private
    returns (bool success)
  {
    assert(spent_proof != bytes32(0));
    assert(claimant != address(0));

    Escrow storage escrow = _lookup_escrow(tok, owner, id);

    require(escrow.state != EscrowState.Invalid,
            "Escrow invalid");

    if (_expired(escrow.unencumbered_at)) {
      return false;
    }

    bool should_slash =
      escrow.spent_proof != bytes32(0) &&
      escrow.spent_proof != spent_proof;

    if (should_slash) {
      _slash_escrow(tok, owner, id, claimant); // inline me?
      return false;
    }

    // implied: escrow.spent_proof == spent_proof.
    bool already_encumbered = escrow.spent_proof != bytes32(0);
    if (already_encumbered) {
      assert(escrow.spent_proof == spent_proof);
      return false;
    }

    // Perform update.
    escrow.state = EscrowState.Withdrawing;
    escrow.unencumbered_at = unencumbered_at;
    escrow.beneficiary = claimant;
    escrow.spent_proof = spent_proof;

    emit EscrowSpent(tok, owner, id, spent_proof, claimant);

    return true;
  }


  //need tok, msg.sender, non-indexed id?
  event InitiateEscrowWithdraw(bytes32 indexed _id);
  function initiate_escrow_withdraw(ERC20 tok, bytes32 id)
    external
  {
    Escrow storage escrow = _lookup_escrow(tok, msg.sender, id);

    require(escrow.state == EscrowState.OnDeposit,
            "Already encumbered");
    assert(escrow.spent_proof == bytes32(0));
    assert(escrow.beneficiary == address(0));

    uint256 unencumbered_at = block.timestamp + LOCKUP_PERIOD_SECONDS;

    escrow.state = EscrowState.Withdrawing;
    escrow.unencumbered_at = unencumbered_at;
    escrow.beneficiary = msg.sender;

    emit InitiateEscrowWithdraw(id);
  }


  //need tok, msg.sender, non-indexed id?
  event FinalizeEscrowWithdraw(bytes32 indexed _id);
  function finalize_escrow_withdraw(ERC20 tok, address owner, bytes32 escrow_id)
    external
  {
    Escrow storage escrow = _lookup_escrow(tok, owner, escrow_id);

    require(_expired(escrow.unencumbered_at),
           "Escrow not withdrawable yet");

    address beneficiary = escrow.beneficiary;

    // Allow proxy to call?
    // TODO maybe allow owner to call
    require(msg.sender == beneficiary,
            "Not the beneficiary");

    uint256 amount = escrow.amount;
    uint256 buffer_amount = escrow.buffer_balance;
    assert(amount == buffer_amount);

    // JE
    //   DR
    escrow.amount = 0; // NGM - for clarity; redundant with later delete
    //   CR
    _credit(tok, beneficiary, amount);

    // JE
    //   DR
    escrow.buffer_balance = 0; // NGM - for clarity; redundant with later delete
    //   CR
    _credit(tok, owner, buffer_amount);

    //delete escrow; <-- does not compile
    delete escrows[address(tok)][owner][escrow_id];

    emit FinalizeEscrowWithdraw(escrow_id);
  }


  // index on market?
  event Exchange(bytes32 indexed itt_hash, ERC20 base, ERC20 dst, uint256 base_amount, uint256 dst_amount, address itt_sender, address poi_sender);
  // Passing structs via calldata fails solc with unimplemented error
  // function exchange(ITT calldata itt, POI calldata poi,...)
  // exchange(ITT memory itt,...) public
  // requires ABIEncoderV2 instead of asm (pick your poison!)
  function exchange(
    ITT memory itt,
    POI memory poi,
    bytes memory tkr_sig
    )
    public // SBE
    returns (bool success)
  {
    // check based on domain separator?
    require(address(this) == itt.BEACON_CONTRACT,
            "Wrong ITT contract");
    require(address(this) == poi.BEACON_CONTRACT,
            "Wrong POI contract");

    // require maker signature for POI?
    // (sig for ITT hash not required since POI references the ITT)
    //require(ECVerify.ecverify(eip712encode(poi_digest), mkr_sig) == itt.sender);
    // Allow proxy to call?
    require(msg.sender == itt.sender, "Unauthorized");


    bytes32 itt_digest = ${ref_eip712HashStruct "itt" ittTy};
    require(itt_digest == poi.itt_hash,
           "ITT hash does not match");

    bytes32 poi_digest = ${ref_eip712HashStruct "poi" poiTy};

    // require taker signature for POI hash
    require(ECVerify.ecverify(eip712encode(poi_digest), tkr_sig) == poi.sender,
           "Invalid signature");

    ERC20 base = ERC20(itt.base);
    ERC20 dst = ERC20(itt.dst);

    uint256 unencumbered_at = block.timestamp + LOCKUP_PERIOD_SECONDS;
    Escrow storage escrow = _lookup_escrow(base, itt.sender, itt.forfeiture_fee_id);
    if (escrow.state != EscrowState.OnDeposit/*can_trade - NROS*/) {
      return false;
    }

    // If the escrow is double spent, will slash and return false.
    // If escrow is already challenged, will return false.
    // assert should follow from escrow.state == EscrowState.OnDeposit
    assert(_supply_escrow_spend_proof(base, itt.sender, itt.forfeiture_fee_id, unencumbered_at, itt.sender, itt_digest));

    // JE
    //   DR
    _debit(base, itt.sender, itt.base_amount);
    //   CR
    _credit(base, poi.sender, itt.base_amount);

    // JE
    //   DR
    _debit(dst, poi.sender, itt.dst_amount);
    //   CR
    _credit(dst, itt.sender, itt.dst_amount);

    emit Exchange(itt_digest, base, dst, itt.base_amount, itt.dst_amount, itt.sender, poi.sender);
    return true;
  }


  function _calc_challenge_expiry(uint256 challenge_period_seconds)
    private view returns (uint256)
  {
    return block.timestamp.add(challenge_period_seconds);
  }
  event InitiateChallenge(bytes32 indexed itt_hash, ERC20 base, ERC20 dst, uint256 base_amount, uint256 dst_amount, address itt_sender, address challenger);
  event ForfeitChallenge(bytes32 indexed itt_hash); // non-indexed hash?
  function initiate_challenge(ITT memory itt, bytes memory mkr_sig)
    public // SBE
    returns (bool success)
  {
    // NROS!
    // address challenger = msg.sender
    bytes32 itt_digest = ${ref_eip712HashStruct "itt" ittTy};
    require(ECVerify.ecverify(eip712encode(itt_digest), mkr_sig) == itt.sender,
           "Invalid signature");

    ERC20 base = ERC20(itt.base);
    ERC20 dst = ERC20(itt.dst);

    Challenge storage c = _lookup_challenge(base, dst, itt_digest);
    Escrow storage escrow = _lookup_escrow(base, itt.sender, itt.forfeiture_fee_id);

    require(c.ends_at == 0,
            "ITT already challenged");

    // NROS!
    //uint256 ends_at = block.timestamp.add(itt.challenge_period_seconds);

    Deposit storage dpst = _lookup_deposit(base, itt.sender);

    /* assumption: forfeiture fee token is itt.base. */
    // must come before _supply_escrow_spend which is mutating.
    bool can_trade =
      escrow.state == EscrowState.OnDeposit &&
      dpst.deposit_balance >= itt.base_amount;


    /** Create challenge **/

    // First, lock up the escrow by supplying a proof.
    // If the escrow is double spent, will slash and return false.
    // If escrow is withdrawing or challenged, will return false.
    if (!_supply_escrow_spend_proof(base, itt.sender, itt.forfeiture_fee_id, _calc_challenge_expiry(itt.challenge_period_seconds), msg.sender, itt_digest)) {
      return false; // don't revert slashing
    }

    // Initiate challenge struct
    c.ends_at = _calc_challenge_expiry(itt.challenge_period_seconds);
    c.escrow_id = itt.forfeiture_fee_id;
    c.incumbent = itt.sender; // optimization: could omit if forfeited
    c.challenger = msg.sender;

    // Always lock challenger funds.
    // JE
    //   DR
    _debit(dst, msg.sender, itt.dst_amount);
    //   CR
    c.dst_amount = itt.dst_amount;

    if (can_trade) {
      // Lock up incumbent funds, full challenge initiated.
      // JE
      //   DR
      _debit(base, itt.sender, itt.base_amount);
      //   CR
      c.base_amount = itt.base_amount;

    } else {
      // Simple withdraw or insufficient funds, implicit
      // reject of all challenges.
      c.forfeited = true;
    }

    emit InitiateChallenge(itt_digest, base, dst, itt.base_amount, itt.dst_amount, itt.sender, msg.sender);
    if (!can_trade) {
      emit ForfeitChallenge(itt_digest);
    }
    return true;
  }


  function forfeit_challenge(ERC20 base, ERC20 dst, bytes32 itt_hash)
    external
  {
    Challenge storage c = _lookup_challenge(base, dst, itt_hash);

    require(c.incumbent == msg.sender,
            "Not authorized");

    require(!_expired(c.ends_at),
           "Challenge ended");

    c.forfeited = true;

    // Rollback incumbent funds only, challenger must stay locked for
    // duration of challenge.
    // JE
    uint256 base_amount = c.base_amount;
    //   DR
    c.base_amount = 0;
    //   CR
    _credit(base, c.incumbent, base_amount);

    emit ForfeitChallenge(itt_hash);
  }


  event AcceptChallenge(bytes32 indexed itt_hash);
  // If the challenge is still available
  //    (i.e. escrow unslashed and challenge not expired) and
  //    msg.sender is the incumbent,
  //    accept challenge and do the trade.
  function accept_challenge(ERC20 base, ERC20 dst, bytes32 itt_hash)
    external
  {
    // optimization opportunity: if read-only, just make copy.
    Challenge storage c = _lookup_challenge(base, dst, itt_hash);

    Escrow storage escrow = _lookup_escrow(base, c.incumbent, c.escrow_id);

    require(c.ends_at != 0,
            "Challenge invalid");

    require(msg.sender == c.incumbent,
           "Not authorized");

    require(!_expired(c.ends_at),
            "Challenge expired");

    require(escrow.state != EscrowState.Invalid,
           "Forfeiture fee slashed, can't trade");

    require(!c.forfeited,
            "Challenge already forfeited");

    assert(escrow.beneficiary == c.challenger);
    assert(escrow.spent_proof == itt_hash);

    // swap assets

    // JE
    uint256 dst_amt = c.dst_amount;
    //   DR
    c.dst_amount = 0; // NGM
    //   CR
    _credit(dst, c.challenger, dst_amt);

    // JE
    uint256 base_amt = c.base_amount;
    //   DR
    c.base_amount = 0; // NGM
    //   CR
    _credit(base, c.incumbent, base_amt);

    // Do ordinary withdrawal process for escrow funds
    escrow.beneficiary = c.incumbent;
    escrow.unencumbered_at = block.timestamp + LOCKUP_PERIOD_SECONDS;

    delete challenges[address(base)][address(dst)][itt_hash];

    emit AcceptChallenge(itt_hash);
  }


  event ReturnChallengeFunds(bytes32 indexed itt_hash);
  // If the challenge is unavailable,
  //   check that the challenge has expired or has been forfeited and
  //   return funds to parties.
  function return_challenge_funds(ERC20 base, ERC20 dst, bytes32 itt_hash)
    external
  {
    // optimization opportunity: if read-only, just make copy.
    Challenge storage c = _lookup_challenge(base, dst, itt_hash);

    require(c.ends_at != 0,
            "Challenge invalid");

    require(msg.sender == c.incumbent || msg.sender == c.challenger,
            "Not authorized");

    Escrow storage escrow = _lookup_escrow(base, c.incumbent, c.escrow_id);

    bool slashed = escrow.state == EscrowState.Invalid;
    require(_expired(c.ends_at) || slashed);

    // return funds.
    // JE
    //   DR
    _debit(base, c.incumbent, c.base_amount);
    //   CR
    c.base_amount = 0; // NGM - for clarity; redundant with later delete

    // JE
    //   DR
    _debit(dst, c.challenger, c.dst_amount);
    //   CR
    c.dst_amount = 0; // NGM - for clarity; redundant with later delete.

    if (!slashed) {
      assert(escrow.beneficiary == c.challenger);
      assert(escrow.spent_proof == itt_hash);
      // Add additional escrow lockup to give
      // opportunity for double spend proof to be provided in the
      // case of very short lockups.
      escrow.unencumbered_at = c.ends_at + LOCKUP_PERIOD_SECONDS;
    }

    delete challenges[address(base)][address(dst)][itt_hash];

    emit ReturnChallengeFunds(itt_hash);
  }
}
