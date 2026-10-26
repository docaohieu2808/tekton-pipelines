"""Convert the OpenAPI schemas inside CustomResourceDefinition files to JSON schema files
that kubeconform can use (one file per kind and version: <kind>_<version>.json, lower case).

Strict mode: an object schema that lists `properties` gets additionalProperties=false, like
kubectl's own validation, unless the CRD marks it x-kubernetes-preserve-unknown-fields.

kubeconform's bundled openapi2jsonschema.py cannot be used here: it also treats a *field*
that happens to be called "properties" (Tekton has one in params/results) as the JSON schema
keyword and produces a schema that fails to load. This converter walks the schema by keyword
position, so field names never collide with keywords.
"""
import json
import sys

import yaml


def convert(node):
    """Convert one schema object (not a name->schema map)."""
    if not isinstance(node, dict):
        return node
    out = {}
    for key, value in node.items():
        if key == "properties" and isinstance(value, dict):
            # name -> schema map: convert each value, never the map itself
            out[key] = {name: convert(sub) for name, sub in value.items()}
        elif key in ("items", "additionalProperties") and isinstance(value, dict):
            out[key] = convert(value)
        elif key in ("allOf", "anyOf", "oneOf") and isinstance(value, list):
            out[key] = [convert(sub) for sub in value]
        else:
            out[key] = value
    if out.pop("x-kubernetes-int-or-string", False):
        out.pop("type", None)
        out["oneOf"] = [{"type": "integer"}, {"type": "string"}]
    if ("properties" in out and "additionalProperties" not in out
            and not out.get("x-kubernetes-preserve-unknown-fields")):
        out["additionalProperties"] = False
    return out


def main(out_dir, crd_files):
    written = 0
    for path in crd_files:
        with open(path) as handle:
            for doc in yaml.safe_load_all(handle):
                if not doc or doc.get("kind") != "CustomResourceDefinition":
                    continue
                kind = doc["spec"]["names"]["kind"].lower()
                for version in doc["spec"]["versions"]:
                    schema = version.get("schema", {}).get("openAPIV3Schema")
                    if not schema:
                        continue
                    target = f"{out_dir}/{kind}_{version['name']}.json"
                    with open(target, "w") as out:
                        json.dump(convert(schema), out)
                    written += 1
    print(f"Generated {written} schemas in {out_dir}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
