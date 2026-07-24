#!/usr/bin/env python3
"""Verification suite for the Fintegrate simulator reply writer (stdlib only).

Runnable with no test harness / no third-party deps:

    python3 scripts/test_fint_sim_reply.py            # verbose
    python3 -m unittest scripts.test_fint_sim_reply   # discovery form

Covers the M10 T10 mandate mode (pain.009/.010/.011 -> pain.012 ISR/SBSR/PBSR
trio) and guards the unchanged collections mode as a regression.
"""
import importlib.util
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
REPLY = SCRIPTS / "fint_sim_reply.py"

_spec = importlib.util.spec_from_file_location("fint_sim_reply", REPLY)
fsr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fsr)

REJECT_REASONS = {"AC01", "AC04", "MD01", "MS03"}


def pain009(out_msg_id: str, mndt_req_id: str, mndt_id: str, orgnl_e2e: str = None) -> str:
    """A byte-shape match of mrw's PainMandateWriter pain.009 output. A-69: carries
    OrgnlEndToEndId after MndtId; omitted when None to model a pre-A-69 outbound file."""
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<Document xmlns="urn:iso:std:iso:20022:tech:xsd:pain.009.001.03">',
        "  <!-- SYNTHETIC-CONTRACT PAIN009 skeleton (A-60) -->",
        "  <MndtInitnReq>",
        f"    <GrpHdr><MsgId>{out_msg_id}</MsgId><NbOfMndts>1</NbOfMndts></GrpHdr>",
        "    <Mndt>",
        f"      <MndtReqId>{mndt_req_id}</MndtReqId>",
        f"      <MndtId>{mndt_id}</MndtId>",
    ]
    if orgnl_e2e is not None:
        lines.append(f"      <OrgnlEndToEndId>{orgnl_e2e}</OrgnlEndToEndId>")
    lines += [
        "      <CdtrAcct><Id>6200000021</Id></CdtrAcct>",
        "      <Dbtr><Nm>ACME PTY LTD</Nm></Dbtr>",
        "      <DbtrAcct><Id>6299999999</Id><Brnch>250655</Brnch></DbtrAcct>",
        '      <MaxAmt Ccy="ZAR">100.00</MaxAmt>',
        "    </Mndt>",
        "  </MndtInitnReq>",
        "</Document>",
    ]
    return "\n".join(lines)


def sts(body: str) -> str:
    return re.search(r"<MndtSts>([^<]+)</MndtSts>", body).group(1)


def reason(body: str):
    m = re.search(r"<Rsn>([^<]+)</Rsn>", body)
    return m.group(1) if m else None


class MandateMode(unittest.TestCase):

    def _emit(self, out_dir: Path, client: str, i: int):
        out_msg_id, mndt_req_id = f"OMS{i:032d}", f"MRQ{i:032d}"
        mndt_id, e2e = f"MREF-{i:05d}", f"E2E{i:032d}"
        src = out_dir / f"{client}_{out_msg_id}_PAIN009.xml"
        src.write_text(pain009(out_msg_id, mndt_req_id, mndt_id, e2e))
        stem = f"{client}_{out_msg_id}"
        fsr.mandate_reply(src, stem, out_dir, auth_delay_seconds=0.0)
        return stem, e2e

    def test_trio_rotation_and_delayed_auth(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            n = 120
            results = [self._emit(out, "FNBCC01", i) for i in range(n)]

            rjct, delayed, reasons = 0, 0, set()
            for stem, e2e in results:
                isr = (out / f"{stem}_ISR.xml").read_text()
                sbsr = (out / f"{stem}_SBSR.xml").read_text()
                pbsr = (out / f"{stem}_PBSR.xml").read_text()
                # ISR structural accept, SBSR sponsoring-bank pending (always).
                self.assertTrue(isr.startswith("<ISR>"), "ISR leg root")
                self.assertEqual(sts(isr), "ACCP")
                self.assertEqual(sts(sbsr), "PDNG")
                self.assertTrue(pbsr.startswith("<PBSR>"), "PBSR leg root")
                # every correlation id round-trips into every leg, including the A-69
                # OrgnlEndToEndId echoed verbatim from the outbound pain.
                for leg in (isr, sbsr, pbsr):
                    self.assertIn("<OrgnlMsgId>OMS", leg)
                    self.assertIn("<MndtReqId>MRQ", leg)
                    self.assertIn("<MndtId>MREF-", leg)
                    self.assertIn(f"<OrgnlEndToEndId>{e2e}</OrgnlEndToEndId>", leg)

                first = sts(pbsr)
                auth = out / f"{stem}-AUTH_PBSR.xml"
                if first == "RJCT":
                    rjct += 1
                    r = reason(pbsr)
                    self.assertIn(r, REJECT_REASONS, "rotating reason from the seeded set")
                    reasons.add(r)
                    self.assertFalse(auth.exists(), "a rejected mandate has no delayed second leg")
                elif first == "PDNG":
                    delayed += 1
                    self.assertTrue(auth.exists(), "every-7th delayed auth emits a SECOND PBSR")
                    self.assertEqual(sts(auth.read_text()), "ACCP", "debtor auth resolves to ACCP")
                    self.assertTrue(auth.read_text().startswith("<PBSR>"), "second leg is a PBSR token")
                else:
                    self.assertEqual(first, "ACCP", "default final is ACCP")
                    self.assertFalse(auth.exists())

            self.assertGreater(rjct, 0, "every-4th rejections must occur over 120 mandates")
            self.assertGreater(delayed, 0, "every-7th delayed-auth must occur over 120 mandates")
            self.assertEqual(reasons, REJECT_REASONS, "all four reasons rotate into use")

    def test_deterministic_replay(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            stems = [self._emit(out, "FNBCC01", i) for i in range(40)]
            before = {p.name: p.read_text() for p in out.glob("*.xml") if "PAIN009" not in p.name}
            for i in range(40):
                self._emit(out, "FNBCC01", i)  # replay
            after = {p.name: p.read_text() for p in out.glob("*.xml") if "PAIN009" not in p.name}
            self.assertEqual(before, after, "re-running the sim yields byte-identical reply files")

    def test_cli_mandate_flag(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            src = out / "FNBRF01_OMS7_PAIN009.xml"
            src.write_text(pain009("OMS7", "MRQ7", "MREF-7", "E2E7"))
            subprocess.run(
                [sys.executable, str(REPLY), "--mandate", "--auth-delay-seconds", "0",
                 str(src), "FNBRF01_OMS7", str(out)],
                check=True, capture_output=True, text=True)
            isr = (out / "FNBRF01_OMS7_ISR.xml").read_text()
            self.assertEqual(sts(isr), "ACCP")
            self.assertIn("<OrgnlEndToEndId>E2E7</OrgnlEndToEndId>", isr, "A-69: the CLI echoes the e2e")
            self.assertEqual(sts((out / "FNBRF01_OMS7_SBSR.xml").read_text()), "PDNG")
            self.assertTrue((out / "FNBRF01_OMS7_PBSR.xml").exists())

    def test_outbound_without_e2e_degrades_gracefully(self):
        """A-69: a pre-A-69 outbound (no OrgnlEndToEndId) must not crash the sim and
        must emit legs that simply omit the echo (old fixtures stay byte-identical)."""
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            src = out / "FNBRF01_OMS8_PAIN009.xml"
            src.write_text(pain009("OMS8", "MRQ8", "MREF-8"))  # no e2e
            fsr.mandate_reply(src, "FNBRF01_OMS8", out, auth_delay_seconds=0.0)
            for token in ("ISR", "SBSR", "PBSR"):
                body = (out / f"FNBRF01_OMS8_{token}.xml").read_text()
                self.assertNotIn("<OrgnlEndToEndId>", body, "no e2e echoed when the outbound carries none")
                self.assertIn("<MndtSts>", body, "the leg is still well-formed")


class CollectionsRegression(unittest.TestCase):

    def test_collections_mode_unchanged(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            src = out / "FNBCC01_MSG1_PAIN008.xml"
            src.write_text("<Document><MsgId>MSG1</MsgId>"
                           + "".join(f"<EndToEndId>E{i}</EndToEndId>" for i in range(4))
                           + "</Document>")
            subprocess.run(
                [sys.executable, str(REPLY), str(src), "FNBCC01_MSG1", str(out)],
                check=True, capture_output=True, text=True)
            isr = (out / "FNBCC01_MSG1_ISR.xml").read_text()
            pbsr = (out / "FNBCC01_MSG1_PBSR.xml").read_text()
            self.assertIn("<GrpSts>ACCP</GrpSts>", isr)
            self.assertIn("<TxSts>RJCT</TxSts>", pbsr)  # every 4th tx (index 3)
            self.assertIn("<Rsn>AC04</Rsn>", pbsr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
