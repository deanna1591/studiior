"""RPC Service Invoice generator.

make_invoice(data, out_path)            -> filled invoice (what a client downloads)
make_invoice(None, out_path, blank=True) -> fillable blank template
"""
from reportlab.lib.pagesizes import A4
from reportlab.pdfgen import canvas
from reportlab.lib.colors import HexColor, Color
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.utils import ImageReader
from decimal import Decimal, ROUND_HALF_UP
import os

FD = "/home/claude/fonts"
for n, f in [("SG", "SG-Regular.ttf"), ("SG-M", "SG-Medium.ttf"), ("SG-B", "SG-Bold.ttf"),
             ("BM", "BM-Regular.ttf"), ("BM-I", "BM-Italic.ttf"),
             ("MONO", "SpaceMono-Regular.ttf"), ("MONO-B", "SpaceMono-Bold.ttf")]:
    pdfmetrics.registerFont(TTFont(n, os.path.join(FD, f)))

PINK = HexColor("#F5066B")
BLUSH = HexColor("#FFD3E6")
PEARL = HexColor("#F5F3F4")
BLACK = HexColor("#000000")
PEWTER = HexColor("#8A8889")
WHITE = HexColor("#FFFFFF")
LINE = HexColor("#E2DDDF")

LOGO = "/home/claude/logo_clean.png"

SELLER = {
    "name": "REFORM COLLECTIVE FITNESS STUDIO",
    "prop": "Deanna Fae S. Visperas  ·  Prop.",
    "tin": "VAT REG. TIN  309-279-300-00000",
    "addr1": "Unit 2D, Phoenix Center, #329 Alabang-Zapote Road",
    "addr2": "Barangay Talon Uno, Las Piñas City",
    "addr3": "Metro Manila, Philippines",
    "email": "rpcstudiomanila@gmail.com",
    "tel": "(02) 8241 6136",
    "mobile": "0998 580 2192",
}

W, H = A4
M = 40


def peso(v):
    if v is None or v == "":
        return ""
    v = Decimal(v).quantize(Decimal("0.01"), ROUND_HALF_UP)
    return "₱ {:,.2f}".format(v)


def compute(items, scpwd_discount=0, withholding=0):
    """All prices are VAT-inclusive (12%)."""
    gross = sum(Decimal(str(i["qty"])) * Decimal(str(i["price"])) for i in items)
    vat = (gross / Decimal("1.12") * Decimal("0.12")).quantize(Decimal("0.01"), ROUND_HALF_UP)
    net = gross - vat
    disc = Decimal(str(scpwd_discount))
    total_due = net - disc
    wht = Decimal(str(withholding))
    amount_due = total_due - wht
    add_vat = vat if disc == 0 else Decimal("0")  # SC/PWD sales are VAT-exempt
    total = amount_due + add_vat
    return {
        "Total Sales (VAT Inclusive)": gross,
        "Less: VAT": vat,
        "Amount Net of VAT": net,
        "Less: SC/PWD Discount": disc,
        "Total Due": total_due,
        "Less: Withholding Tax": wht,
        "Amount Due": amount_due,
        "Add: VAT": add_vat,
        "TOTAL AMOUNT DUE": total,
        "VATable Sales": net if disc == 0 else Decimal("0"),
        "VAT-Exempt Sales": Decimal("0") if disc == 0 else net,
        "VAT Zero-Rated Sales": Decimal("0"),
        "VAT Amount": add_vat,
    }


class Inv:
    def __init__(self, path, blank):
        self.c = canvas.Canvas(path, pagesize=A4)
        self.blank = blank
        self.c.setTitle("RPC Service Invoice")
        self.c.setAuthor("Reform Collective Fitness Studio")

    def text(self, x, y, s, font="SG", size=9, color=BLACK, align="l", spacing=0):
        c = self.c
        c.setFillColor(color)
        c.setFont(font, size)
        if spacing:
            t = c.beginText()
            t.setFont(font, size)
            t.setCharSpace(spacing)
            wdt = pdfmetrics.stringWidth(s, font, size) + spacing * (len(s) - 1)
            if align == "r":
                x -= wdt
            elif align == "c":
                x -= wdt / 2
            t.setTextOrigin(x, y)
            t.textOut(s)
            c.drawText(t)
            return
        if "₱" in s and font.startswith("MONO"):
            pf = "SG-B" if font.endswith("B") else "SG-M"
            pre, rest = s.split("₱", 1)
            parts = [(pre, font), ("₱", pf), (rest, font)]
            wdt = sum(pdfmetrics.stringWidth(t, f, size) for t, f in parts)
            if align == "r": x -= wdt
            elif align == "c": x -= wdt / 2
            for t, f in parts:
                c.setFont(f, size); c.drawString(x, y, t); x += pdfmetrics.stringWidth(t, f, size)
            return
        {"l": c.drawString, "r": c.drawRightString, "c": c.drawCentredString}[align](x, y, s)

    def label(self, x, y, s, color=PEWTER, align="l", size=6.5):
        self.text(x, y, s.upper(), "MONO-B", size, color, align, spacing=0.6)

    def field(self, name, x, y, w, h, value="", font="SG-M", size=9.5, align="l", color=BLACK):
        """Value area: filled text, or an AcroForm field when blank."""
        if self.blank:
            q = {"l": 0, "c": 1, "r": 2}[align]
            self.c.acroForm.textfield(
                name=name, x=x, y=y, width=w, height=h, fontName="Helvetica", fontSize=size - 0.5,
                borderWidth=0, borderColor=None, fillColor=None, textColor=color,
                forceBorder=False, maxlen=200, fieldFlags="", annotationFlags="print")
            return
        if value:
            tx = {"l": x + 2, "c": x + w / 2, "r": x + w - 3}[align]
            self.text(tx, y + (h - size) / 2 + 1.5, value, font, size, color, align)


def make_invoice(data, out_path, blank=False):
    inv = Inv(out_path, blank)
    c = inv.c
    d = data or {}

    # page + accent bars
    c.setFillColor(PEARL); c.rect(0, 0, W, H, 0, 1)
    c.setFillColor(PINK); c.rect(0, H - 7, W, 7, 0, 1)
    c.setFillColor(BLACK); c.rect(0, 0, W, 4, 0, 1)

    # ---------- header ----------
    top = H - 34
    logo = ImageReader(LOGO)
    lw, lh = logo.getSize()
    LW = 132; LH = LW * lh / lw
    c.drawImage(logo, M - 4, top - LH, LW, LH, mask="auto")

    inv.text(W - M, top - 22, "Service Invoice", "BM", 27, BLACK, "r")
    inv.label(W - M - 118, top - 44, "Invoice No.", align="l")
    inv.field("invoice_no", W - M - 118, top - 64, 118, 18, d.get("invoice_no", ""), "MONO-B", 15, "r", PINK)
    if not blank:
        pass
    c.setStrokeColor(PINK); c.setLineWidth(0.8); c.line(W - M - 118, top - 66, W - M, top - 66)
    inv.label(W - M - 118, top - 80, "Date", align="l")
    inv.field("date", W - M - 118, top - 98, 118, 16, d.get("date", ""), "SG-M", 10, "r")
    c.setStrokeColor(LINE); c.line(W - M - 118, top - 99, W - M, top - 99)

    # ---------- seller ----------
    y = top - LH - 22
    inv.text(M, y, SELLER["name"], "SG-B", 12.5, BLACK, spacing=0.4)
    inv.text(M, y - 14, SELLER["prop"], "SG", 8.5, PEWTER)
    inv.text(M, y - 26, SELLER["tin"], "MONO-B", 8.5, BLACK)
    inv.text(M, y - 40, SELLER["addr1"], "SG", 8.5)
    inv.text(M, y - 51, SELLER["addr2"], "SG", 8.5)
    inv.text(M, y - 62, SELLER["addr3"], "SG", 8.5)

    cx = W - M - 168
    rows = [("Email", SELLER["email"]), ("Landline", SELLER["tel"]), ("Mobile", SELLER["mobile"])]
    for i, (k, v) in enumerate(rows):
        yy = y - 26 - i * 14
        inv.label(cx, yy, k)
        inv.text(W - M, yy, v, "SG-M", 8.5, BLACK, "r")
    seller_bottom = y - 74

    # ---------- sold to ----------
    y = seller_bottom - 14
    c.setFillColor(PINK); c.rect(M, y - 1, 3, 9, 0, 1)
    inv.label(M + 8, y, "Sold to", BLACK, size=7.5)
    box_top = y - 8
    bh = 104
    c.setFillColor(WHITE); c.setStrokeColor(LINE); c.setLineWidth(0.7)
    c.roundRect(M, box_top - bh, W - 2 * M, bh, 6, 1, 1)
    split = M + (W - 2 * M) * 0.64
    c.line(split, box_top - 34, split, box_top)
    c.line(M, box_top - 34, W - M, box_top - 34)
    c.line(M, box_top - 68, W - M, box_top - 68)
    c.line(split, box_top - bh, split, box_top - 68)
    pad = 10
    inv.label(M + pad, box_top - 12, "Registered Name")
    inv.field("client_name", M + pad - 2, box_top - 31, split - M - 2 * pad, 16, d.get("client_name", ""))
    inv.label(split + pad, box_top - 12, "TIN")
    inv.field("client_tin", split + pad - 2, box_top - 31, W - M - split - 2 * pad, 16, d.get("client_tin", ""), "MONO", 9)
    inv.label(M + pad, box_top - 46, "Business Address")
    inv.field("client_address", M + pad - 2, box_top - 65, W - 2 * M - 2 * pad, 16, d.get("client_address", ""))
    inv.label(M + pad, box_top - 80, "Email")
    inv.field("client_email", M + pad - 2, box_top - 99, split - M - 2 * pad, 16, d.get("client_email", ""))
    inv.label(split + pad, box_top - 80, "Member / Booking Ref")
    inv.field("client_ref", split + pad - 2, box_top - 99, W - M - split - 2 * pad, 16, d.get("client_ref", ""), "MONO", 9)

    # ---------- items ----------
    y = box_top - bh - 18
    tw = W - 2 * M
    cols = [M, M + tw * 0.56, M + tw * 0.68, M + tw * 0.84, W - M]
    hh = 22
    c.setFillColor(BLACK); c.roundRect(M, y - hh, tw, hh, 5, 0, 1)
    c.rect(M, y - hh, tw, 6, 0, 1)
    heads = ["Item Description / Nature of Service", "Qty", "Unit Price", "Amount"]
    inv.label(cols[0] + 10, y - 14, heads[0], WHITE, size=7)
    inv.label((cols[1] + cols[2]) / 2, y - 14, heads[1], WHITE, "c", 7)
    inv.label(cols[3] - 8, y - 14, heads[2], WHITE, "r", 7)
    inv.label(cols[4] - 10, y - 14, heads[3], WHITE, "r", 7)
    rh = 24
    nrows = 5
    items = d.get("items", [])
    c.setFillColor(WHITE); c.rect(M, y - hh - rh * nrows, tw, rh * nrows, 0, 1)
    for r in range(nrows):
        ry = y - hh - rh * (r + 1)
        if r % 2 == 1:
            c.setFillColor(HexColor("#FBF9FA")); c.rect(M, ry, tw, rh, 0, 1)
        c.setStrokeColor(LINE); c.setLineWidth(0.6); c.line(M, ry, W - M, ry)
        it = items[r] if r < len(items) else None
        inv.field(f"item_{r+1}_desc", cols[0] + 8, ry + 4, cols[1] - cols[0] - 12, 16, it and it["desc"] or "", "SG-M", 9)
        inv.field(f"item_{r+1}_qty", cols[1] + 2, ry + 4, cols[2] - cols[1] - 4, 16, it and str(it["qty"]) or "", "MONO", 9, "c")
        inv.field(f"item_{r+1}_price", cols[2] + 2, ry + 4, cols[3] - cols[2] - 6, 16, it and peso(it["price"]) or "", "MONO", 8.5, "r")
        amt = it and peso(Decimal(str(it["qty"])) * Decimal(str(it["price"]))) or ""
        inv.field(f"item_{r+1}_amount", cols[3] + 2, ry + 4, cols[4] - cols[3] - 8, 16, amt, "MONO-B", 8.5, "r")
    for cxx in cols[1:4]:
        c.setStrokeColor(LINE); c.line(cxx, y - hh, cxx, y - hh - rh * nrows)
    c.setStrokeColor(LINE); c.rect(M, y - hh - rh * nrows, tw, rh * nrows, 1, 0)
    inv.text(M, y - hh - rh * nrows - 12, "All prices are VAT-inclusive (12%).", "SG", 7, PEWTER)

    # ---------- bottom: left = payment, right = tax summary ----------
    yb = y - hh - rh * nrows - 26
    rx = M + tw * 0.53
    rw = W - M - rx
    summary = compute(items, d.get("scpwd_discount", 0), d.get("withholding", 0)) if items else {}
    keys = ["Total Sales (VAT Inclusive)", "Less: VAT", "Amount Net of VAT", "Less: SC/PWD Discount",
            "Total Due", "Less: Withholding Tax", "Amount Due", "Add: VAT"]
    srh = 16.5
    c.setFillColor(WHITE); c.setStrokeColor(LINE)
    c.roundRect(rx, yb - srh * len(keys) - 6, rw, srh * len(keys) + 6, 5, 1, 1)
    for i, k in enumerate(keys):
        ry = yb - 3 - srh * (i + 1)
        if i: c.setStrokeColor(LINE); c.line(rx + 8, ry + srh, rx + rw - 8, ry + srh)
        inv.text(rx + 10, ry + 5, k, "SG", 8, BLACK)
        fname = "sum_" + k.lower().replace(":", "").replace("(", "").replace(")", "").replace("/", "").replace(" ", "_").replace("-", "_")
        inv.field(fname, rx + rw * 0.55, ry + 1, rw * 0.45 - 10, srh - 2,
                  peso(summary[k]) if summary else "", "MONO", 8, "r")
    # total band
    ty = yb - srh * len(keys) - 6 - 8 - 30
    c.setFillColor(PINK); c.roundRect(rx, ty, rw, 30, 5, 0, 1)
    inv.label(rx + 10, ty + 11.5, "Total Amount Due", WHITE, size=7.5)
    inv.field("total_amount_due", rx + rw * 0.45, ty + 5, rw * 0.55 - 10, 20,
              peso(summary["TOTAL AMOUNT DUE"]) if summary else "", "MONO-B", 12, "r", WHITE)
    # VAT breakdown
    vk = ["VATable Sales", "VAT-Exempt Sales", "VAT Zero-Rated Sales", "VAT Amount"]
    vy = ty - 8
    for i, k in enumerate(vk):
        ry = vy - srh * (i + 1)
        inv.text(rx + 10, ry + 5, k, "SG", 7.8, PEWTER)
        fname = "vat_" + k.lower().replace("-", "_").replace(" ", "_")
        inv.field(fname, rx + rw * 0.55, ry + 1, rw * 0.45 - 10, srh - 2,
                  peso(summary[k]) if summary else "", "MONO", 8, "r")
        c.setStrokeColor(LINE); c.setDash(1, 2); c.line(rx + 8, ry, rx + rw - 8, ry); c.setDash()
    right_bottom = vy - srh * len(vk)

    # left column: payment details
    lx = M; lw_ = rx - M - 18
    inv.label(lx, yb - 4, "Payment", BLACK, size=7.5)
    c.setFillColor(PINK); c.rect(lx - 8, yb - 5, 3, 9, 0, 1)
    methods = ["Cash", "GCash", "Maya", "Card", "Bank Transfer"]
    sel = d.get("method", "")
    mx = lx; my = yb - 26
    for m_ in methods:
        bw = pdfmetrics.stringWidth(m_, "SG-M", 8) + 22
        if mx + bw > lx + lw_:
            mx = lx; my -= 20
        on = (m_ == sel)
        c.setLineWidth(0.8)
        c.setStrokeColor(PINK if on else LINE); c.setFillColor(BLUSH if on else WHITE)
        c.roundRect(mx, my - 4, bw, 15, 7.5, 1, 1)
        if blank:
            c.acroForm.checkbox(name=f"pay_{m_.lower().replace(' ', '_')}", x=mx + 4.5, y=my - 0.5, size=8,
                                borderColor=PINK, fillColor=WHITE, buttonStyle="check",
                                textColor=PINK, borderWidth=0.6, forceBorder=True)
        else:
            c.setFillColor(PINK if on else WHITE); c.setStrokeColor(PINK if on else PEWTER)
            c.circle(mx + 8.5, my + 3.5, 3, 1, 1)
        inv.text(mx + 15, my + 0.5, m_, "SG-M", 8, BLACK)
        mx += bw + 6

    def line_field(lbl, name, val, yy, font="SG-M", size=9):
        inv.label(lx, yy, lbl)
        inv.field(name, lx - 2, yy - 20, lw_, 16, val, font, size)
        c.setStrokeColor(LINE); c.setLineWidth(0.7); c.line(lx, yy - 21, lx + lw_, yy - 21)

    fy = my - 26
    line_field("Payment Reference No.", "payment_ref", d.get("payment_ref", ""), fy, "MONO", 9)
    line_field("Amount Received", "amount_received", d.get("amount_received", ""), fy - 36, "MONO-B", 9.5)
    # SC / PWD
    half = (lw_ - 10) / 2
    yy = fy - 72
    inv.label(lx, yy, "OSCA / PWD ID No.")
    inv.field("osca_pwd_no", lx - 2, yy - 20, half, 16, d.get("osca_pwd_no", ""), "MONO", 9)
    inv.label(lx + half + 10, yy, "SC / PWD Signature")
    c.setStrokeColor(LINE); c.line(lx, yy - 21, lx + half, yy - 21); c.line(lx + half + 10, yy - 21, lx + lw_, yy - 21)
    yy -= 36
    inv.label(lx, yy, "Received by (Authorized Signature)")
    inv.field("received_by", lx - 2, yy - 22, lw_, 18, d.get("received_by", ""), "BM-I", 12)
    c.setStrokeColor(BLACK); c.setLineWidth(0.7); c.line(lx, yy - 24, lx + lw_, yy - 24)

    # PAID stamp (filled invoices only)
    if d.get("paid"):
        c.saveState()
        c.translate(lx + lw_ - 56, fy - 48)
        c.rotate(-12)
        c.setStrokeColor(PINK); c.setLineWidth(1.6)
        c.roundRect(-44, -15, 88, 32, 6, 1, 0)
        c.setLineWidth(0.6); c.roundRect(-41, -12, 82, 26, 4, 1, 0)
        inv.text(0, -5, "PAID", "MONO-B", 17, PINK, "c", spacing=3)
        c.restoreState()

    # ---------- footer ----------
    fyb = min(right_bottom, yy - 24) - 26
    c.setStrokeColor(BLACK); c.setLineWidth(0.8); c.line(M, fyb, W - M, fyb)
    inv.text(M, fyb - 22, "Thank you for moving with us.", "BM-I", 14, BLACK)
    inv.text(M, fyb - 35, "Keep this invoice for your records.", "SG", 7.3, PEWTER)

    comp = d.get("compliance", {})
    lines = [
        ("Acknowledgment Cert. / ATP No.", comp.get("permit", "xxxxxxxxxxxxxxx")),
        ("Date Issued", comp.get("permit_date", "xxxxxxxxxx")),
        ("Approved Series", comp.get("series", "0000001 – 9999999")),
    ]
    by = fyb - 18
    for i, (k, v) in enumerate(lines):
        inv.label(W - M - 74, by - i * 11, k, size=5.8, align="r")
        inv.text(W - M, by - i * 11, v, "MONO", 6.8, BLACK, "r")

    c.showPage()
    c.save()


if __name__ == "__main__":
    import sys
    sample = {
        "invoice_no": "No. 000147",
        "date": "November 3, 2026",
        "client_name": "Maria Angela Reyes",
        "client_tin": "",
        "client_address": "Las Piñas City, Metro Manila",
        "client_email": "angela.reyes@email.com",
        "client_ref": "RPC-M-0231",
        "items": [
            {"desc": "Reformer Class Pack  ·  10 Sessions", "qty": 1, "price": 9500},
            {"desc": "Single Reformer Class  ·  Burn", "qty": 1, "price": 1050},
        ],
        "method": "GCash",
        "payment_ref": "GC 7012 3345 9981",
        "amount_received": "₱ 10,550.00",
        "received_by": "RPC Front Desk",
        "paid": True,
    }
    make_invoice(sample, sys.argv[1])
    make_invoice(None, sys.argv[2], blank=True)
