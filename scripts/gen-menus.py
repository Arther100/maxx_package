import zipfile
import re
import json
from pathlib import Path

path = Path(r"c:\Users\vijay.a\Downloads\Maxx_Events_Menu.docx")
with zipfile.ZipFile(path) as z:
    xml = z.read("word/document.xml").decode("utf-8")

lines = [t.strip() for t in re.findall(r"<w:t[^>]*>([^<]*)</w:t>", xml) if t.strip()]

categories = {"breakfast": [], "lunch": [], "dinner": []}
current = None
current_menu = None


def flush():
    global current_menu
    if current and current_menu:
        categories[current].append(current_menu)
    current_menu = None


for line in lines:
    if line == "BREAKFAST MENUS":
        flush()
        current = "breakfast"
        continue
    if line == "LUNCH MENUS":
        flush()
        current = "lunch"
        continue
    if line == "DINNER MENUS":
        flush()
        current = "dinner"
        continue
    if not current:
        continue
    if re.match(r"^(Tiffin|Lunch|Dinner)\s+\d+$", line):
        flush()
        current_menu = {"name": line, "items": []}
        continue
    if current_menu is not None:
        if line.startswith("Contact:") or line.startswith("Minimum order"):
            continue
        if line in ("Sweet", "Starter", "Main Course"):
            current_menu["items"].append("— " + line + " —")
        else:
            current_menu["items"].append(line.replace("&amp;", "&"))

flush()

out = Path(__file__).resolve().parent.parent / "booking_form" / "veg-menus.js"
out.write_text(
    "window.VEG_MENUS = "
    + json.dumps(categories, ensure_ascii=False, indent=2)
    + ";\n\nwindow.MENU_CATEGORIES = "
    + json.dumps(
        [
            {"id": "breakfast", "label": "Breakfast", "icon": "🌅", "sub": "Tiffin menus"},
            {"id": "lunch", "label": "Lunch", "icon": "☀️", "sub": "South Indian lunch combos"},
            {"id": "dinner", "label": "Dinner", "icon": "🌙", "sub": "Premium dinner menus"},
        ],
        ensure_ascii=False,
        indent=2,
    )
    + ";\n",
    encoding="utf-8",
)

for k, v in categories.items():
    print(k, len(v), "menus")
print("written", out)
