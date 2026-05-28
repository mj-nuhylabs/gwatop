//
//  KoreanUniversities.swift
//  GwaTop
//
//  한국 4년제 대학교 목록 — 회원가입 시 학교 선택 picker 의 데이터 소스.
//  공식 API 가 없어 정적 배열로 보관 (대교협/NEIS 데이터 기반 주요 대학 ~80 곳).
//  검색은 이름/별칭(영문 + 약칭) 모두 매치.
//
//  TODO: 추후 백엔드에 /v1/universities 엔드포인트가 생기면 동적 fetch 로 교체.
//

import Foundation

struct KoreanUniversity: Identifiable, Hashable {
    let id: String      // 안정적 식별자 (영문 약칭 또는 한글)
    let name: String    // 표시명
    let aliases: [String] // 검색 보조 (영문 약칭, 흔한 별칭)
    let region: String  // 검색용 (서울 / 경기 / 부산 / …)
}

enum KoreanUniversities {
    /// 주요 4년제 대학교 — 가나다 순. 추후 보완 가능.
    static let all: [KoreanUniversity] = [
        // ── 서울 ──────────────────────────────
        .init(id: "korea",        name: "고려대학교",       aliases: ["KU", "Korea University"], region: "서울"),
        .init(id: "kookmin",      name: "국민대학교",       aliases: ["Kookmin"], region: "서울"),
        .init(id: "kwangwoon",    name: "광운대학교",       aliases: ["KW"], region: "서울"),
        .init(id: "konkuk",       name: "건국대학교",       aliases: ["KKU", "Konkuk"], region: "서울"),
        .init(id: "dongguk",      name: "동국대학교",       aliases: ["DGU", "Dongguk"], region: "서울"),
        .init(id: "duksung",      name: "덕성여자대학교",   aliases: ["Duksung"], region: "서울"),
        .init(id: "myongji",      name: "명지대학교",       aliases: ["MJU"], region: "서울"),
        .init(id: "sangmyung",    name: "상명대학교",       aliases: ["SMU"], region: "서울"),
        .init(id: "seoul-tech",   name: "서울과학기술대학교", aliases: ["SeoulTech"], region: "서울"),
        .init(id: "seoul-citu",   name: "서울시립대학교",   aliases: ["UoS"], region: "서울"),
        .init(id: "snu",          name: "서울대학교",       aliases: ["SNU", "Seoul National University"], region: "서울"),
        .init(id: "sogang",       name: "서강대학교",       aliases: ["Sogang"], region: "서울"),
        .init(id: "sungshin",     name: "성신여자대학교",   aliases: ["Sungshin"], region: "서울"),
        .init(id: "skku",         name: "성균관대학교",     aliases: ["SKKU", "Sungkyunkwan"], region: "서울"),
        .init(id: "sejong",       name: "세종대학교",       aliases: ["Sejong"], region: "서울"),
        .init(id: "sookmyung",    name: "숙명여자대학교",   aliases: ["Sookmyung"], region: "서울"),
        .init(id: "soongsil",     name: "숭실대학교",       aliases: ["SSU", "Soongsil"], region: "서울"),
        .init(id: "ewha",         name: "이화여자대학교",   aliases: ["Ewha", "EWU"], region: "서울"),
        .init(id: "jongsin",      name: "총신대학교",       aliases: ["CSU"], region: "서울"),
        .init(id: "chungang",     name: "중앙대학교",       aliases: ["CAU", "Chungang"], region: "서울"),
        .init(id: "hanyang",      name: "한양대학교",       aliases: ["HYU", "Hanyang"], region: "서울"),
        .init(id: "hufs",         name: "한국외국어대학교", aliases: ["HUFS"], region: "서울"),
        .init(id: "hongik",       name: "홍익대학교",       aliases: ["HIU", "Hongik"], region: "서울"),
        .init(id: "yonsei",       name: "연세대학교",       aliases: ["YSU", "Yonsei"], region: "서울"),
        .init(id: "kyunghee",     name: "경희대학교",       aliases: ["KHU", "Kyunghee"], region: "서울"),

        // ── 경기/인천 ─────────────────────────
        .init(id: "ajou",         name: "아주대학교",       aliases: ["Ajou"], region: "경기"),
        .init(id: "gachon",       name: "가천대학교",       aliases: ["Gachon"], region: "경기"),
        .init(id: "dankook",      name: "단국대학교",       aliases: ["Dankook"], region: "경기"),
        .init(id: "hanyang-erica",name: "한양대학교 ERICA", aliases: ["ERICA"], region: "경기"),
        .init(id: "kaist-seoul",  name: "한국항공대학교",   aliases: ["KAU"], region: "경기"),
        .init(id: "kw-katholic",  name: "가톨릭대학교",     aliases: ["CUK"], region: "경기"),
        .init(id: "kw-suwon",     name: "수원대학교",       aliases: ["USW"], region: "경기"),
        .init(id: "kyonggi",      name: "경기대학교",       aliases: ["KGU"], region: "경기"),
        .init(id: "inha",         name: "인하대학교",       aliases: ["Inha"], region: "인천"),
        .init(id: "incheon",      name: "인천대학교",       aliases: ["INU"], region: "인천"),

        // ── 부산/울산/경남 ────────────────────
        .init(id: "pusan",        name: "부산대학교",       aliases: ["PNU"], region: "부산"),
        .init(id: "pukyong",      name: "부경대학교",       aliases: ["PKNU"], region: "부산"),
        .init(id: "dong-a",       name: "동아대학교",       aliases: ["DAU"], region: "부산"),
        .init(id: "donga-busan",  name: "동의대학교",       aliases: ["DEU"], region: "부산"),
        .init(id: "kmu",          name: "한국해양대학교",   aliases: ["KMOU"], region: "부산"),
        .init(id: "kyungsung",    name: "경성대학교",       aliases: ["KSU"], region: "부산"),
        .init(id: "ulsan",        name: "울산대학교",       aliases: ["Ulsan"], region: "울산"),
        .init(id: "changwon",     name: "창원대학교",       aliases: ["CWNU"], region: "경남"),
        .init(id: "knu",          name: "경상국립대학교",   aliases: ["GNU"], region: "경남"),

        // ── 대구/경북 ─────────────────────────
        .init(id: "knu-daegu",    name: "경북대학교",       aliases: ["KNU"], region: "대구"),
        .init(id: "keimyung",     name: "계명대학교",       aliases: ["Keimyung"], region: "대구"),
        .init(id: "daegu",        name: "대구대학교",       aliases: ["DU"], region: "대구"),
        .init(id: "yeungnam",     name: "영남대학교",       aliases: ["YNU"], region: "경북"),
        .init(id: "andong",       name: "안동대학교",       aliases: ["ANU"], region: "경북"),

        // ── 광주/전남/전북 ────────────────────
        .init(id: "chonnam",      name: "전남대학교",       aliases: ["JNU", "CNU-Gwangju"], region: "광주"),
        .init(id: "chosun",       name: "조선대학교",       aliases: ["Chosun"], region: "광주"),
        .init(id: "jbnu",         name: "전북대학교",       aliases: ["JBNU"], region: "전북"),
        .init(id: "wonkwang",     name: "원광대학교",       aliases: ["WKU"], region: "전북"),
        .init(id: "mokpo",        name: "목포대학교",       aliases: ["MNU"], region: "전남"),

        // ── 대전/충남/충북 ────────────────────
        .init(id: "cnu",          name: "충남대학교",       aliases: ["CNU"], region: "대전"),
        .init(id: "hannam",       name: "한남대학교",       aliases: ["HNU"], region: "대전"),
        .init(id: "hanbat",       name: "한밭대학교",       aliases: ["HBNU"], region: "대전"),
        .init(id: "chungbuk",     name: "충북대학교",       aliases: ["CBNU"], region: "충북"),
        .init(id: "soonchunhyang",name: "순천향대학교",     aliases: ["SCH"], region: "충남"),
        .init(id: "kongju",       name: "공주대학교",       aliases: ["KNU-Kongju"], region: "충남"),

        // ── 강원/제주 ─────────────────────────
        .init(id: "kangwon",      name: "강원대학교",       aliases: ["KNU-Kangwon"], region: "강원"),
        .init(id: "hallym",       name: "한림대학교",       aliases: ["Hallym"], region: "강원"),
        .init(id: "jeju",         name: "제주대학교",       aliases: ["JNU-Jeju"], region: "제주"),

        // ── 과학기술원/특수목적 ────────────────
        .init(id: "kaist",        name: "한국과학기술원 (KAIST)", aliases: ["KAIST"], region: "대전"),
        .init(id: "postech",      name: "포항공과대학교 (POSTECH)", aliases: ["POSTECH"], region: "경북"),
        .init(id: "gist",         name: "광주과학기술원 (GIST)",    aliases: ["GIST"], region: "광주"),
        .init(id: "unist",        name: "울산과학기술원 (UNIST)",   aliases: ["UNIST"], region: "울산"),
        .init(id: "dgist",        name: "대구경북과학기술원 (DGIST)", aliases: ["DGIST"], region: "대구"),
        .init(id: "kentech",      name: "한국에너지공과대학교 (KENTECH)", aliases: ["KENTECH"], region: "전남"),
        .init(id: "kpu",          name: "한국기술교육대학교",       aliases: ["KOREATECH"], region: "충남"),
        .init(id: "kmou-mokpo",   name: "목포해양대학교",       aliases: ["MMU"], region: "전남"),
        .init(id: "police",       name: "경찰대학",             aliases: ["KNPU"], region: "충남"),
        .init(id: "kma",          name: "육군사관학교",         aliases: ["KMA"], region: "서울"),

        // 기타 자주 검색되는 사립
        .init(id: "myungji-yongin",name: "명지대학교 (자연)",   aliases: ["MJU-Yongin"], region: "경기"),
        .init(id: "kyungwon",     name: "경원대학교",          aliases: ["Kyungwon"], region: "경기"),
        .init(id: "halla",        name: "한라대학교",          aliases: ["Halla"], region: "강원"),
        .init(id: "joongbu",      name: "중부대학교",          aliases: ["JBM"], region: "충남"),
    ]

    /// 이름 또는 alias 가 query 를 포함하면 매치 (대소문자 무시).
    static func search(_ query: String) -> [KoreanUniversity] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { u in
            if u.name.lowercased().contains(q) { return true }
            if u.region.lowercased().contains(q) { return true }
            return u.aliases.contains { $0.lowercased().contains(q) }
        }
    }
}
