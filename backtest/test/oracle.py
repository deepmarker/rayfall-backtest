"""Independent exact accounting checks for seeded REJECT-policy scenarios.

Run from backtest: python3 -I test/oracle.py. Only standard-library
modules are needed. Position limits do not bind; SCALE and limits have
separate hand-calculated fixtures. RAYFORCE selects the executable.
"""

import csv
import os
import random
import subprocess
import tempfile
from pathlib import Path

SYMS = ['A', 'B', 'C']
STEPS = 16
FIELDS = {
    'equity': ['cash', 'mv', 'equity', 'realized', 'fees', 'unrealized'],
    'positions': ['sym', 'qty', 'basis', 'mark', 'mv', 'unrealized'],
    'fills': ['order_id', 'sym', 'side', 'qty', 'price', 'notional', 'fee', 'basis_removed', 'realized'],
}


def reference(cash0, ppm, instruments, bars, targets):
    cash, realized, fees, order_id = cash0, 0, 0, 0
    qty, basis, mark = [0] * 3, [0] * 3, [None] * 3
    out = {name: [] for name in FIELDS}
    for step in range(STEPS + 1):
        for i, sym in enumerate(SYMS):
            if (step - 1, sym) in bars:
                mark[i] = bars[step - 1, sym][1]
        values = [qty[i] * (mark[i] or 0) * instruments[sym][0]
                  for i, sym in enumerate(SYMS)]
        for i, sym in enumerate(SYMS):
            out['positions'].append([sym, qty[i], basis[i], mark[i], values[i], values[i] - basis[i]])
        value = sum(values)
        out['equity'].append([cash, value, cash + value, realized, fees, value - sum(basis)])
        if step == STEPS:
            break
        pending = []
        for i, sym in enumerate(SYMS):
            if (step, sym) not in targets:
                continue
            target = targets[step, sym]
            delta = target - qty[i]
            if not delta:
                continue
            quantity = abs(delta)
            current_id, order_id = order_id, order_id + 1
            multiplier, min_qty, min_notional = instruments[sym]
            if (target < 0 or quantity < min_qty or mark[i] is None
                    or quantity * mark[i] * multiplier < min_notional):
                continue
            pending.append((delta > 0, i, current_id, quantity))
        # False sorts before True: sells, then buys, each in symbol order.
        for buy, i, current_id, quantity in sorted(pending):
            sym = SYMS[i]
            if (step, sym) not in bars:
                continue
            price = bars[step, sym][0]
            notional = quantity * price * instruments[sym][0]
            fee = (notional * ppm + 999999) // 1000000
            removed, profit = 0, 0
            if buy:
                if notional + fee > cash:
                    continue
                cash -= notional + fee
                qty[i] += quantity
                basis[i] += notional
            else:
                removed = basis[i] * quantity // qty[i]
                profit = notional - removed
                qty[i] -= quantity
                basis[i] -= removed
                cash += notional - fee
                realized += profit
            fees += fee
            out['fills'].append([current_id, sym, 'BUY' if buy else 'SELL',
                                 quantity, price, notional, fee, removed, profit])
    return out


def table(names, rows, types):
    columns = []
    for index, typ in enumerate(types):
        cells = ' '.join(str(row[index]) for row in rows)
        columns.append(f"(as '{typ} [{cells}])")
    return '(table [' + ' '.join(names) + '] (list ' + ' '.join(columns) + '))'


def check_case(seed, directory):
    rng = random.Random(seed)
    cash0 = rng.randrange(1000, 10001)
    ppm = rng.choice([0, 1, 1000, 3333, 10000])
    instruments = {s: (rng.randrange(1, 4), rng.randrange(1, 5), rng.randrange(0, 61)) for s in SYMS}
    bars = {(k, s): (rng.randrange(5, 101), rng.randrange(5, 101))
            for k in range(STEPS) for s in SYMS if rng.random() > .2}
    targets = {(k, s): rng.randrange(-3, 31)
               for k in range(STEPS) for s in SYMS if rng.random() > .25}
    want = reference(cash0, ppm, instruments, bars, targets)
    instrument_rows = [[s, *instruments[s]] for s in SYMS]
    bar_rows = [[f'2026.01.01D{k:02d}:00:00.000', s, *v] for (k, s), v in bars.items()]
    target_rows = [[f'2026.01.01D{k:02d}:00:00.000', s, v] for (k, s), v in targets.items()]
    for rows in (instrument_rows, bar_rows, target_rows):
        rng.shuffle(rows)
    code = f'''(load "bt.rfl")
(load "report.rfl")
(set cfg {{cash0: {cash0} fee_ppm: {ppm} start: 2026.01.01D00:00:00.000 period: 0D01:00:00 steps: {STEPS} max_weight_ppm: 1000000000000 max_gross_ppm: 1000000000000 buy_policy: 'REJECT}})
(bt_run cfg {table(['sym', 'mult', 'min_qty', 'min_notional'], instrument_rows, ['SYM', 'I64', 'I64', 'I64'])}
{table(['ts', 'sym', 'o', 'c'], bar_rows, ['TIMESTAMP', 'SYM', 'I64', 'I64'])}
{table(['ts', 'sym', 'target'], target_rows, ['TIMESTAMP', 'SYM', 'I64'])})
(bt_check_identities)
(bt_check_limits)
(bt_check_attribution (bt_attribution))
(bt_write_outputs "{directory}/")
'''
    path = directory / 'case.rfl'
    path.write_text(code)
    result = subprocess.run([os.environ.get('RAYFORCE', 'rayforce'), str(path)],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if result.returncode:
        raise AssertionError(f'seed {seed}: {result.stdout}{result.stderr}')
    for name, fields in FIELDS.items():
        with (directory / (name + '.csv')).open() as source:
            raw = list(csv.DictReader(source))
        got = [[row[field] if field in ('sym', 'side') else
                (None if row[field] == '' else int(row[field])) for field in fields] for row in raw]
        if got != want[name]:
            raise AssertionError(f'seed {seed} {name}: got {got}, want {want[name]}')


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='bt-oracle-') as tmp:
        for seed in range(50):
            check_case(seed, Path(tmp))
    print('PASS independent oracle: 50 seeds, 3 instruments, 16 steps, REJECT')
