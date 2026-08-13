class ClockExchange {
  const ClockExchange({required this.t0, required this.t1, required this.t2, required this.t3});
  final int t0;
  final int t1;
  final int t2;
  final int t3;

  double get roundTripMicros => (t3 - t0 - (t2 - t1)).toDouble();
  double get offsetMicros => ((t1 - t0) + (t2 - t3)) / 2.0;
}

class ClockEstimate {
  const ClockEstimate(this.offsetMicros);
  final double offsetMicros;
}
