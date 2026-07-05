export function statsSummary(rows) {
  const s = {
    totalCost: 0,
    totalTokens: 0,
    input: 0,
    output: 0,
    cacheCreate: 0,
    cacheRead: 0,
    cache: 0,
    cacheRate: 0,
    topModel: null,
    activeDays: 0,
    dailyAvg: 0,
    peakDay: null,
  };
  const modelCost = {};
  let peak = null;
  for (const r of rows) {
    s.totalCost += r.cost || 0;
    s.totalTokens += r.tokens || 0;
    s.input += r.input || 0;
    s.output += r.output || 0;
    s.cacheCreate += r.cacheCreate || 0;
    s.cacheRead += r.cacheRead || 0;
    for (const m in r.byModel || {})
      modelCost[m] = (modelCost[m] || 0) + (r.byModel[m].cost || 0);
    if ((r.tokens || 0) > 0) {
      s.activeDays += 1;
      if (!peak || r.tokens > peak.tokens)
        peak = { date: r.date, tokens: r.tokens, cost: r.cost };
    }
  }
  s.cache = s.cacheCreate + s.cacheRead;
  const denom = s.cacheRead + s.input;
  s.cacheRate = denom > 0 ? s.cacheRead / denom : 0;
  s.dailyAvg = s.activeDays > 0 ? s.totalCost / s.activeDays : 0;
  const models = Object.keys(modelCost);
  s.topModel = models.length
    ? models.reduce((a, b) => (modelCost[b] > modelCost[a] ? b : a))
    : null;
  s.peakDay = peak;
  return s;
}
