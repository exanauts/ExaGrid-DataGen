#!/usr/bin/env python3
"""
Read HDF5 Contingency Analysis Results
Author: Yousu Chen

Prerequisites:
    pip install h5py numpy

Usage:
    python read_scenario.py scenario_000001.h5
    python read_scenario.py scenario_000001.h5 --structure   # Show file structure
    python read_scenario.py scenario_000001.h5 --element grid/nodes/load  # Read specific element
"""

import argparse
import h5py
import numpy as np


def print_structure(filepath):
    """Print the full HDF5 file structure."""
    print("=" * 60)
    print(f"HDF5 Structure: {filepath}")
    print("=" * 60)

    def visitor(name, obj):
        indent = "  " * name.count("/")
        if isinstance(obj, h5py.Dataset):
            print(f"{indent}{name}: {obj.shape} {obj.dtype}")
        else:
            print(f"{indent}{name}/")
            for key, val in obj.attrs.items():
                print(f"{indent}  @{key} = {val}")

    with h5py.File(filepath, "r") as f:
        f.visititems(visitor)


def read_element(filepath, element_path):
    """Read a specific element from the HDF5 file."""
    with h5py.File(filepath, "r") as f:
        if element_path not in f:
            print(f"Error: '{element_path}' not found in {filepath}")
            print("\nAvailable paths:")
            f.visititems(lambda name, obj: print(f"  {name}"))
            return

        obj = f[element_path]
        print(f"Path: {element_path}")

        if isinstance(obj, h5py.Dataset):
            data = obj[:]
            print(f"Type: Dataset")
            print(f"Shape: {data.shape}")
            print(f"Dtype: {data.dtype}")
            print(f"\nData:\n{data}")
        else:
            print(f"Type: Group")
            print(f"Attributes:")
            for key, val in obj.attrs.items():
                print(f"  {key} = {val}")
            print(f"Children:")
            for key in obj.keys():
                print(f"  {key}")


def read_scenario(filepath):
    """Read and summarize a scenario HDF5 file."""
    print("=" * 60)
    print(f"Reading: {filepath}")
    print("=" * 60)

    with h5py.File(filepath, "r") as f:
        # Input load with weights
        load_input = f["grid/nodes/load"][:]  # [n_load, 4]: pd, qd, weight_p, weight_q
        print(f"\nInput loads: {load_input.shape}")
        print("  Columns: [pd, qd, weight_p, weight_q]")
        print(f"  Total P demand: {load_input[:, 0].sum():.2f} MW")
        print(f"  Total Q demand: {load_input[:, 1].sum():.2f} MVAr")

        # Base case OPF solution
        base_vm = f["base_solution/opf/nodes/bus"][:, 1]  # voltage magnitude
        base_pg = f["base_solution/opf/nodes/generator"][:, 0]  # active generation
        base_load_served = f["base_solution/opf/nodes/load"][:]  # [n_load, 2]

        print("\nBase case OPF:")
        print(f"  Total generation: {base_pg.sum():.2f} MW")
        print(f"  Voltage range: {base_vm.min():.4f} - {base_vm.max():.4f} p.u.")

        # Calculate load shedding
        p_shed = load_input[:, 0].sum() - base_load_served[:, 0].sum()
        q_shed = load_input[:, 1].sum() - base_load_served[:, 1].sum()
        print(f"  Load shed: P={p_shed:.2f} MW, Q={q_shed:.2f} MVAr")

        # Contingency definitions
        n_cont = f["contingencies"].attrs["count"]
        cont_types = f["contingencies/types"][:]  # 0=line, 1=gen
        cont_names = [n.decode() if isinstance(n, bytes) else n for n in f["contingencies/names"][:]]
        cont_ids = [i.decode() if isinstance(i, bytes) else i for i in f["contingencies/ids"][:]]

        print("\n" + "-" * 60)
        print(f"Contingencies: {n_cont}")
        print("-" * 60)
        for i in range(n_cont):
            type_str = "LINE" if cont_types[i] == 0 else "GEN"
            print(f"  {i+1}: {cont_names[i]} ({type_str} outage, id={cont_ids[i]})")

        # Post-contingency OPF solutions
        print("\n" + "-" * 60)
        print("Post-contingency OPF results:")
        print("-" * 60)
        print("  Name                  | Cost ($)    | P Shed (MW) | Status")
        print("  " + "-" * 56)

        for i in range(n_cont):
            g = f[f"post_contingency/contingency_{i+1:06d}"]

            pf_converged = g.attrs["pf_converged"] == 1
            opf_converged = g.attrs["opf_converged"] == 1

            if opf_converged:
                load_served = g["opf/nodes/load"][:]
                objective = g["opf"].attrs["objective"]

                p_shed = load_input[:, 0].sum() - load_served[:, 0].sum()

                status = "PF+OPF OK" if pf_converged else "OPF OK"
                print(f"  {cont_names[i]:<21} | {objective:>11.2f} | {p_shed:>11.2f} | {status}")
            else:
                status = "PF OK, OPF FAIL" if pf_converged else "BOTH FAIL"
                print(f"  {cont_names[i]:<21} | {'-':>11} | {'-':>11} | {status}")

        # Generator redispatch example
        print("\n" + "-" * 60)
        print("Generator Redispatch (Base -> Contingency 1):")
        print("-" * 60)
        base_gen = f["base_solution/opf/nodes/generator"][:]
        cont1_gen = f["post_contingency/contingency_000001/opf/nodes/generator"][:]

        dpg = cont1_gen[:, 0] - base_gen[:, 0]
        significant = np.abs(dpg) > 0.01

        if significant.any():
            print("  Gen#     Base Pg     Cont Pg      Delta")
            for i in np.where(significant)[0]:
                print(f"  {i+1:>4}     {base_gen[i,0]:>7.3f}     {cont1_gen[i,0]:>7.3f}     {dpg[i]:>+7.3f}")
        else:
            print("  No significant redispatch (all |delta| < 0.01 p.u.)")

        print("\n" + "=" * 60)


def main():
    parser = argparse.ArgumentParser(description="Read HDF5 Contingency Analysis Results")
    parser.add_argument("filepath", help="Path to scenario HDF5 file")
    parser.add_argument("--structure", action="store_true", help="Print file structure")
    parser.add_argument("--element", type=str, help="Read specific element by path")

    args = parser.parse_args()

    if args.structure:
        print_structure(args.filepath)
    elif args.element:
        read_element(args.filepath, args.element)
    else:
        read_scenario(args.filepath)


if __name__ == "__main__":
    main()
