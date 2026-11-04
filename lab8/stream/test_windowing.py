"""Run: python -m pytest test_windowing.py  (or python test_windowing.py)"""

from windowing import FailureMonitor


def ev(inv, status, t, method="card"):
    return {"invoiceId": inv, "status": status, "modifiedDate": t, "paymentMethod": method}


def test_counts_and_closes_after_lateness():
    m = FailureMonitor(lateness=120, min_finished=1)
    assert m.add(ev("a", "success", "2026-10-01T08:15:10Z")) == []
    assert m.add(ev("b", "failure", "2026-10-01T08:15:50Z")) == []
    # 08:17:59 - 120 s = 08:15:59: the 08:15 window is still open
    assert m.add(ev("c", "created", "2026-10-01T08:17:59Z")) == []
    closed = m.add(ev("d", "created", "2026-10-01T08:18:00Z"))
    assert len(closed) == 1
    stats = closed[0].by_method["card"]
    assert (stats.finished, stats.failed) == (2, 1)
    assert closed[0].alerts == ["card"]  # 50% > 10%


def test_duplicates_dropped():
    m = FailureMonitor()
    m.add(ev("a", "success", "2026-10-01T08:15:10Z"))
    m.add(ev("a", "success", "2026-10-01T08:15:10Z"))
    assert m.duplicates == 1


def test_late_event_rejected_only_after_window_closed():
    m = FailureMonitor(lateness=120)
    m.add(ev("a", "success", "2026-10-01T08:15:10Z"))
    m.add(ev("b", "success", "2026-10-01T08:17:30Z"))  # watermark 08:15:30
    m.add(ev("c", "failure", "2026-10-01T08:15:40Z"))  # late but within the wait: counted
    assert m.late == 0
    m.add(ev("d", "success", "2026-10-01T08:20:00Z"))  # closes 08:15..08:17
    m.add(ev("e", "failure", "2026-10-01T08:15:59Z"))  # its window is gone
    assert m.late == 1


def test_zero_lateness_rejects_out_of_order():
    m = FailureMonitor(lateness=0)
    m.add(ev("a", "success", "2026-10-01T08:16:00Z"))  # closes 08:15
    m.add(ev("b", "success", "2026-10-01T08:15:59Z"))
    assert m.late == 1


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
