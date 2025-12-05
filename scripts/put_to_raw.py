# scripts/put_to_raw.py
import argparse, shutil, os, pathlib, datetime
from pathlib import Path

MAP = {
  "olist_orders_dataset.csv":         ("orders", "olist_orders_dataset.csv"),
  "olist_order_items_dataset.csv":    ("order_items", "olist_order_items_dataset.csv"),
  "olist_customers_dataset.csv":      ("customers", "olist_customers_dataset.csv"),
  "olist_order_payments_dataset.csv": ("payments", "olist_order_payments_dataset.csv"),
  "olist_order_reviews_dataset.csv":  ("reviews", "olist_order_reviews_dataset.csv"),
  "olist_products_dataset.csv":       ("products", "olist_products_dataset.csv"),
  "olist_sellers_dataset.csv":        ("sellers", "olist_sellers_dataset.csv"),
  "olist_geolocation_dataset.csv":    ("geolocation", "olist_geolocation_dataset.csv"),
  "product_category_name_translation.csv": ("category_translation", "product_category_name_translation.csv"),
}

def main(src, dst, ingest_date=None):
  d = ingest_date or datetime.date.today().isoformat()
  src = Path(src); dst = Path(dst)
  for fname, (sub, outname) in MAP.items():
    src_file = src / fname
    if not src_file.exists():
      print(f"[WARN] not found: {src_file}")
      continue
    target = dst / sub / f"ingest_date={d}"
    target.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src_file, target / outname)
    print(f"→ {target/outname}")

if __name__ == "__main__":
  ap = argparse.ArgumentParser()
  ap.add_argument("--src", required=True, help="folder with 9 original Olist CSVs")
  ap.add_argument("--dst", default="data/raw/olist")
  ap.add_argument("--ingest-date", default=None, help="YYYY-MM-DD")
  args = ap.parse_args()
  main(args.src, args.dst, args.ingest_date)
