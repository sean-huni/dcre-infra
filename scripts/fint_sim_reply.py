#!/usr/bin/env python3
"""Fintegrate simulator reply writer (ALLOWED stub: legitimate file-transfer sim).

[SYNTHETIC-CONTRACT R-35] pain.002/.012-family shapes are invented-contemporary.
Not archaeology.

Two modes, one atomic-write discipline (tmp + rename, R-30 boundary):

COLLECTIONS (default) -- for one inbound pain.008 emits three replies into
fint-resp (R-31 names):
  {stem}_ISR.xml   group verdict  <GrpSts>ACCP</GrpSts>
  {stem}_SBSR.xml  per-tx interim TxSts=PDNG
  {stem}_PBSR.xml  per-tx final   TxSts=ACSC, every 4th RJCT + Rsn=AC04

MANDATE (--mandate, M10 T10) -- for one outbound pain.009/.010/.011 (one mandate
per message, written by mrw) emits a pain.012 acceptance TRIO into fint-resp-man,
carrying the correlation identities the AGT response-leg DAG maps through
(out MsgId, MndtReqId, MndtId) plus the A-69 OrgnlEndToEndId echoed verbatim from
the outbound (omitted for pre-A-69 files, so old fixtures stay byte-identical):
  {stem}_ISR.xml   structural accept          <MndtSts>ACCP</MndtSts>
  {stem}_SBSR.xml  sponsoring-bank pending     <MndtSts>PDNG</MndtSts>
  {stem}_PBSR.xml  final ACCP, EXCEPT
     * every 4th mandate -> RJCT with a rotating reason (AC01/AC04/MD01/MS03),
     * every 7th mandate -> delayed debtor auth: PDNG now, then a SECOND
       {stem}-AUTH_PBSR.xml with ACCP after --auth-delay-seconds.
The every-Nth selector is a stable digest of the MndtReqId (the mrw full-identity
key), NOT a mutable counter, so re-running the sim on the same outbound re-emits
byte-identical replies (deterministic, replayable). Distinct filename stems per
token (R-16) keep the per-leg readers' UNIQUE(response_file, mndt_req_id) rows
apart. Those readers are mix, msx and mpx: the single merged reader that owned
that constraint was retired by SCRUM-91 and split three ways.
"""
import argparse
import hashlib
import re
import time
from pathlib import Path

# Rotated across rejected mandates; all four are seeded in
# dcre_man.mandate_reason_code (infra/scripts/seed-man-core.sql).
REJECT_REASONS = ("AC01", "AC04", "MD01", "MS03")


def write_atomic(out_dir: Path, name: str, body: str) -> None:
    tmp = out_dir / (name + ".tmp")
    tmp.write_text(body)
    tmp.rename(out_dir / name)


def _first(text: str, tag: str, src: Path) -> str:
    m = re.search(rf"<{tag}>([^<]+)</{tag}>", text)
    if not m:
        raise SystemExit(f"no <{tag}> in {src}")
    return m.group(1)


def _optional(text: str, tag: str):
    """First <tag>...</tag>, or None when absent: a pre-A-69 outbound carries no
    OrgnlEndToEndId, so the reply degrades gracefully (omit it, never crash)."""
    m = re.search(rf"<{tag}>([^<]+)</{tag}>", text)
    return m.group(1) if m else None


# --- collections mode (behaviour unchanged from the pre-T10 script) ---------
def collections_reply(pain008: Path, base: str, out_dir: Path) -> None:
    text = pain008.read_text()
    msg_id = _first(text, "MsgId", pain008)
    e2es = re.findall(r"<EndToEndId>([^<]+)</EndToEndId>", text)
    if not e2es:
        raise SystemExit(f"no EndToEndId entries in {pain008}")

    def tx_block(e2e, sts, rsn):
        r = f"<Rsn>{rsn}</Rsn>" if rsn else ""
        return f"  <Tx><OrgnlEndToEndId>{e2e}</OrgnlEndToEndId><TxSts>{sts}</TxSts>{r}</Tx>\n"

    isr = (f"<ISR>\n  <OrgnlMsgId>{msg_id}</OrgnlMsgId>\n  <GrpSts>ACCP</GrpSts>\n"
           + "".join(tx_block(e, "ACTC", None) for e in e2es) + "</ISR>\n")
    sbsr = (f"<SBSR>\n  <OrgnlMsgId>{msg_id}</OrgnlMsgId>\n"
            + "".join(tx_block(e, "PDNG", None) for e in e2es) + "</SBSR>\n")
    pbsr = (f"<PBSR>\n  <OrgnlMsgId>{msg_id}</OrgnlMsgId>\n"
            + "".join(tx_block(e, "RJCT", "AC04") if i % 4 == 3 else tx_block(e, "ACSC", None)
                      for i, e in enumerate(e2es)) + "</PBSR>\n")

    write_atomic(out_dir, f"{base}_ISR.xml", isr)
    write_atomic(out_dir, f"{base}_SBSR.xml", sbsr)
    write_atomic(out_dir, f"{base}_PBSR.xml", pbsr)
    print(f"fint-sim: {base} -> ISR/SBSR/PBSR ({len(e2es)} tx)")


# --- mandate mode (M10 T10) -------------------------------------------------
def _ordinal(mndt_req_id: str) -> int:
    """Stable non-negative ordinal over the mandate identity: replay-safe fault
    selection without any mutable per-run counter."""
    return int(hashlib.sha256(mndt_req_id.encode()).hexdigest(), 16)


def _leg(token, out_msg_id, mndt_req_id, mndt_id, status, rsn=None, e2e=None):
    reason = f"  <Rsn>{rsn}</Rsn>\n" if rsn else ""
    # A-69: echo the outbound OrgnlEndToEndId (after MndtId, before MndtSts) so the
    # per-leg readers (mix, msx, mpx) capture a non-NULL e2e. Omitted when the
    # outbound carried none (graceful).
    orgnl_e2e = f"  <OrgnlEndToEndId>{e2e}</OrgnlEndToEndId>\n" if e2e else ""
    return (f"<{token}>\n"
            f"  <!-- SYNTHETIC-CONTRACT pain.012 {token} acceptance report (A-60) -->\n"
            f"  <OrgnlMsgId>{out_msg_id}</OrgnlMsgId>\n"
            f"  <MndtReqId>{mndt_req_id}</MndtReqId>\n"
            f"  <MndtId>{mndt_id}</MndtId>\n"
            f"{orgnl_e2e}"
            f"  <MndtSts>{status}</MndtSts>\n"
            f"{reason}"
            f"</{token}>\n")


def mandate_reply(pain_msg: Path, base: str, out_dir: Path,
                  auth_delay_seconds: float) -> None:
    text = pain_msg.read_text()
    out_msg_id = _first(text, "MsgId", pain_msg)
    mndt_req_id = _first(text, "MndtReqId", pain_msg)
    mndt_id = _first(text, "MndtId", pain_msg)
    # A-69: the OUTGOING mandate request carries OrgnlEndToEndId (mrw); echo it back.
    # A pre-A-69 outbound has none -> e2e stays None and every leg omits it.
    e2e = _optional(text, "OrgnlEndToEndId")

    write_atomic(out_dir, f"{base}_ISR.xml",
                 _leg("ISR", out_msg_id, mndt_req_id, mndt_id, "ACCP", e2e=e2e))
    write_atomic(out_dir, f"{base}_SBSR.xml",
                 _leg("SBSR", out_msg_id, mndt_req_id, mndt_id, "PDNG", e2e=e2e))

    ordinal = _ordinal(mndt_req_id)
    if ordinal % 7 == 6:
        # every 7th: delayed debtor authentication (PDNG now, ACCP after the gap).
        # Takes precedence over the 1/28 collision with the every-4th rejection so
        # the richer two-file auth path is always exercised.
        write_atomic(out_dir, f"{base}_PBSR.xml",
                     _leg("PBSR", out_msg_id, mndt_req_id, mndt_id, "PDNG", e2e=e2e))
        if auth_delay_seconds > 0:
            time.sleep(auth_delay_seconds)
        write_atomic(out_dir, f"{base}-AUTH_PBSR.xml",
                     _leg("PBSR", out_msg_id, mndt_req_id, mndt_id, "ACCP", e2e=e2e))
        final = "PDNG->ACCP (delayed auth)"
    elif ordinal % 4 == 3:
        # every 4th: bank rejection with a rotating reason.
        rsn = REJECT_REASONS[(ordinal // 4) % len(REJECT_REASONS)]
        write_atomic(out_dir, f"{base}_PBSR.xml",
                     _leg("PBSR", out_msg_id, mndt_req_id, mndt_id, "RJCT", rsn, e2e=e2e))
        final = f"RJCT {rsn}"
    else:
        write_atomic(out_dir, f"{base}_PBSR.xml",
                     _leg("PBSR", out_msg_id, mndt_req_id, mndt_id, "ACCP", e2e=e2e))
        final = "ACCP"
    print(f"fint-sim: {base} -> ISR/SBSR/PBSR (mandate {mndt_id}, {final})")


def main() -> None:
    p = argparse.ArgumentParser(description="Fintegrate simulator reply writer")
    p.add_argument("--mandate", action="store_true",
                   help="mandate mode: pain.009/.010/.011 -> pain.012 ISR/SBSR/PBSR trio")
    p.add_argument("--auth-delay-seconds", type=float, default=2.0,
                   help="every-7th delayed debtor-auth gap before the second PBSR (mandate mode)")
    p.add_argument("pain_file")
    p.add_argument("base", help="reply filename stem: <client>_<msgId>")
    p.add_argument("out_dir")
    args = p.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    if args.mandate:
        mandate_reply(Path(args.pain_file), args.base, out_dir, args.auth_delay_seconds)
    else:
        collections_reply(Path(args.pain_file), args.base, out_dir)


if __name__ == "__main__":
    main()
