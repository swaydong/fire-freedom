#!/usr/bin/env python3
import json
import re
import sys


def normalize_name(value):
    return "".join(
        character.lower()
        for character in str(value or "")
        if character.isalnum()
    )


def normalize_hk_code(value, currency):
    prepared = str(value or "").strip().upper()
    has_hk_marker = prepared.endswith(".HK") or prepared.startswith("HK.")
    bare_code = re.sub(r"[^A-Z0-9]", "", prepared.replace(".HK", "").replace("HK.", ""))
    if not bare_code:
        return None
    if bare_code.isdigit() and (
        has_hk_marker or currency == "HKD" or len(bare_code) in (4, 5)
    ):
        return bare_code.zfill(5)
    return bare_code


def unavailable_response():
    return {"error": "akshare_unavailable"}


def load_directory():
    import akshare

    frame = akshare.stock_hk_spot_em()
    records = []
    for _, row in frame.iterrows():
        raw_code = str(row.get("代码", "")).strip()
        if raw_code.endswith(".0"):
            raw_code = raw_code[:-2]
        code = normalize_hk_code(raw_code, "HKD")
        name = str(row.get("名称", "")).strip()
        if code and name:
            records.append(
                {
                    "code": code,
                    "name": name,
                    "normalized_name": normalize_name(name),
                }
            )
    return records


def result_for(position, records):
    product_name = str(position.get("productName") or "").strip()
    currency = str(position.get("currency") or "")
    kind = str(position.get("kind") or "")
    supplied_code = normalize_hk_code(position.get("productCode"), currency)

    if supplied_code:
        if not supplied_code.isdigit() or len(supplied_code) != 5:
            return {"status": "notFound"}
        matches = [record for record in records if record["code"] == supplied_code]
        if len(matches) == 1:
            return {
                "status": "verified",
                "matchedName": matches[0]["name"],
                "matchedCode": supplied_code,
                "currency": "HKD",
                "kind": kind,
            }
        return {"status": "ambiguous" if len(matches) > 1 else "notFound"}

    if currency != "HKD":
        return {"status": "notFound"}
    normalized_name = normalize_name(product_name)
    matches = [
        record
        for record in records
        if record["normalized_name"] == normalized_name
    ]
    if len(matches) == 1:
        return {
            "status": "ambiguous",
            "matchedName": matches[0]["name"],
            "matchedCode": matches[0]["code"],
            "currency": "HKD",
            "kind": kind,
        }
    return {"status": "ambiguous" if len(matches) > 1 else "notFound"}


def main():
    try:
        request = json.load(sys.stdin)
        positions = request.get("positions")
        if not isinstance(positions, list):
            print(json.dumps({"error": "invalid_request"}))
            return
        records = load_directory()
        results = [result_for(position, records) for position in positions]
        print(json.dumps({"results": results}, ensure_ascii=False))
    except (ImportError, ModuleNotFoundError):
        print(json.dumps(unavailable_response()))
    except Exception:
        print(json.dumps(unavailable_response()))


if __name__ == "__main__":
    main()
