#!/usr/bin/env python3
"""Fintegrate simulator reply writer (ALLOWED stub: legitimate file-transfer sim).

[SYNTHETIC-CONTRACT R-35] pain.002-family shapes are invented-contemporary:
<OrgnlMsgId> plus repeated <Tx><OrgnlEndToEndId>|<TxSts>|<Rsn>. Not archaeology.

For one inbound pain.008 emits three replies into fint-resp (R-31 names):
  {client}_{msgId}_ISR.xml   group verdict  <GrpSts>ACCP</GrpSts>
  {client}_{msgId}_SBSR.xml  per-tx interim TxSts=PDNG
  {client}_{msgId}_PBSR.xml  per-tx final   TxSts=ACSC, every 4th RJCT + Rsn=AC04
Writes are atomic (tmp + rename) per R-30 boundary discipline.
"""
import re
import sys
from pathlib import Path


def main() -> None:
    pain008, base, out_dir = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
    text = pain008.read_text()
    msg_id = re.search(r"<MsgId>([^<]+)</MsgId>", text).group(1)
    e2es = re.findall(r"<EndToEndId>([^<]+)</EndToEndId>", text)
    if not e2es:
        raise SystemExit(f"no EndToEndId entries in {pain008}")

    def write_atomic(name: str, body: str) -> None:
        tmp = out_dir / (name + ".tmp")
        tmp.write_text(body)
        tmp.rename(out_dir / name)

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

    write_atomic(f"{base}_ISR.xml", isr)
    write_atomic(f"{base}_SBSR.xml", sbsr)
    write_atomic(f"{base}_PBSR.xml", pbsr)
    print(f"fint-sim: {base} -> ISR/SBSR/PBSR ({len(e2es)} tx)")


if __name__ == "__main__":
    main()
