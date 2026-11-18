const shinkansenStationAliases = new Map<string, string>([
  ["tokyo", "東京"],
  ["ueno", "上野"],
  ["omiya", "大宮"],
  ["shinagawa", "品川"],
  ["shin yokohama", "新横浜"],
  ["odawara", "小田原"],
  ["atami", "熱海"],
  ["shizuoka", "静岡"],
  ["hamamatsu", "浜松"],
  ["nagoya", "名古屋"],
  ["kyoto", "京都"],
  ["shin osaka", "新大阪"],
  ["okayama", "岡山"],
  ["hiroshima", "広島"],
  ["kokura", "小倉"],
  ["hakata", "博多"],
  ["kumamoto", "熊本"],
  ["kagoshima chuo", "鹿児島中央"],
  ["nagasaki", "長崎"],
  ["sendai", "仙台"],
  ["morioka", "盛岡"],
  ["shin aomori", "新青森"],
  ["shin hakodate hokuto", "新函館北斗"],
  ["takasaki", "高崎"],
  ["niigata", "新潟"],
  ["nagano", "長野"],
  ["toyama", "富山"],
  ["kanazawa", "金沢"],
  ["fukui", "福井"],
  ["tsuruga", "敦賀"],
]);

function key(value: string): string {
  return value
    .normalize("NFKD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/[-_]+/gu, " ")
    .replace(/\s+station$/iu, "")
    .replace(/\s+/gu, " ")
    .trim()
    .toLowerCase();
}

export function ekispertSearchQueries(query: string): string[] {
  const value = query.trim();
  const alias = shinkansenStationAliases.get(key(value));
  return alias === undefined ? [value] : [alias, value];
}
