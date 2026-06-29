//
//  GwaTopCourseStudyDetailView.swift
//  GwaTop
//
//  학습 탭에서 과목 카드를 누르면 진입하는 "과목별 학습 상세" 화면.
//  PC(gwatop-web) 의 /courses/[id] 페이지와 동일한 패턴:
//    - 과목 정보 카드
//    - 강의계획서 섹션 (상태/파싱 오류 표시)
//    - 강의자료 섹션 (썸네일 미리보기 카드 그리드 + "자료 추가" 카드)
//  파일을 누르면 GwaTopFileStudyView(전체화면 학습)로 진입한다.
//
//  데이터 로딩/폴링/업로드 알림은 상위 학습 탭(GwaTopAIStudyView)이 그대로 담당하고,
//  이 화면은 전달받은 files 를 렌더링하는 presentational 뷰다. 상위 state 가 갱신되면
//  NavigationLink destination 이 재평가되며 최신 files 가 흘러내려온다.
//

import SwiftUI

struct GwaTopCourseStudyDetailView: View {
    let course: GwaTopCourseDTO
    /// 이 과목의 모든 파일(강의계획서 포함). 상위 학습 탭에서 내려준다.
    let files: [GwaTopFileSummary]
    /// 아직 이 과목의 파일을 불러오는 중인지.
    let isLoading: Bool
    /// 파일 탭 → 상위에서 fullScreenCover 로 학습 화면 표시.
    var onSelectFile: (GwaTopFileSummary) -> Void
    /// 자료 업로드 시트 열기 — 상위 탭이 소유. (이 과목으로 미리 선택됨)
    var onUpload: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            GwaTopHomeTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        courseInfoCard

                        if isLoading && files.isEmpty {
                            ProgressView("불러오는 중…")
                                .padding(.vertical, 40)
                        } else {
                            if !syllabusFiles.isEmpty {
                                syllabusSection
                            }
                            materialsSection
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 32)
                }
            }
        }
        // 상위 탭과 동일하게 커스텀 헤더를 쓰므로 시스템 내비게이션 바는 숨긴다.
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.gwaTopSystem(size: 16, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(GwaTopHomeTheme.surface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Button { onUpload() } label: {
                Image(systemName: "doc.badge.arrow.up")
                    .font(.gwaTopSystem(size: 15, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
                    .frame(width: 38, height: 38)
                    .background(GwaTopHomeTheme.surface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: - Course info card

    private var courseInfoCard: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(course.color.map(Color.gwaTopHex) ?? GwaTopHomeTheme.controlDisabled)
                .frame(width: 5)

            VStack(alignment: .leading, spacing: 6) {
                Text(course.name.isEmpty ? "이름 없는 과목" : course.name)
                    .font(.gwaTopSystem(size: 17, weight: .bold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)

                if let prof = course.professor, !prof.isEmpty {
                    Text(prof)
                        .font(.gwaTopSystem(size: 13, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                }

                if let schedule = course.schedule, !schedule.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(schedule.enumerated()), id: \.offset) { _, slot in
                                Text("\(Self.dayLabel(slot.day)) \(slot.startTime)–\(slot.endTime)")
                                    .font(.gwaTopSystem(size: 11, weight: .semibold))
                                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(GwaTopHomeTheme.surfaceMute)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gwaTopCard(radius: 16, lineWidth: 1)
    }

    // MARK: - Syllabus section

    private var syllabusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("강의계획서")
            VStack(spacing: 10) {
                ForEach(syllabusFiles) { f in
                    Button { onSelectFile(f) } label: { syllabusRow(f) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func syllabusRow(_ f: GwaTopFileSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: f.fileType))
                .font(.gwaTopSystem(size: 16, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textSecondary)
                .frame(width: 32, height: 32)
                .background(GwaTopHomeTheme.surfaceMute)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(f.filename)
                    .font(.gwaTopSystem(size: 14, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    statusIcon(f)
                    Text(Self.dateFormatter.string(from: f.createdAt))
                        .font(.gwaTopSystem(size: 11, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                }

                if let err = f.parseError, !err.isEmpty {
                    Text(err)
                        .font(.gwaTopSystem(size: 11, weight: .medium))
                        .foregroundStyle(GwaTopHomeTheme.danger)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.gwaTopSystem(size: 12, weight: .semibold))
                .foregroundStyle(GwaTopHomeTheme.textTertiary)
                .padding(.top, 9)
        }
        .padding(12)
        .gwaTopCard(radius: 14, lineWidth: 1)
    }

    // MARK: - Materials section (썸네일 그리드)

    private var materialsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("강의자료 · \(materialFiles.count)개")

            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 12) {
                addMaterialCard
                ForEach(materialFiles) { f in
                    Button { onSelectFile(f) } label: { materialCard(f) }
                        .buttonStyle(.plain)
                }
            }

            if materialFiles.isEmpty {
                Text("PDF / PPTX / DOCX 자료를 올리면 주차별로 자동 정리돼요.")
                    .font(.gwaTopSystem(size: 12, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textTertiary)
                    .padding(.top, 2)
            }
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    /// "자료 추가" — 그리드 첫 칸. 업로드 시트 열기. (웹의 점선 추가 카드와 동일)
    private var addMaterialCard: some View {
        Button { onUpload() } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.gwaTopSystem(size: 22, weight: .bold))
                Text("자료 추가")
                    .font(.gwaTopSystem(size: 13, weight: .bold))
            }
            .foregroundStyle(GwaTopHomeTheme.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 150)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        GwaTopHomeTheme.line,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func materialCard(_ f: GwaTopFileSummary) -> some View {
        VStack(spacing: 0) {
            // 썸네일 (4:3) + 처리/실패 오버레이
            Color.clear
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .overlay { GwaTopFileThumbnail(file: f) }
                .overlay { thumbnailStateOverlay(f) }
                .clipped()

            Rectangle()
                .fill(GwaTopHomeTheme.line)
                .frame(height: 1)

            // 메타
            VStack(alignment: .leading, spacing: 7) {
                Text(f.filename)
                    .font(.gwaTopSystem(size: 13, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    typeBadge(f.fileType)
                    weekChip(f)
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
        }
        .gwaTopCard(radius: 14, lineWidth: 1)
    }

    /// 처리 중/실패 상태를 썸네일 위에 반투명 오버레이로.
    @ViewBuilder
    private func thumbnailStateOverlay(_ f: GwaTopFileSummary) -> some View {
        if Self.readyStatuses.contains(f.status) {
            EmptyView()
        } else if f.status == "failed" {
            ZStack {
                GwaTopHomeTheme.background.opacity(0.7)
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.gwaTopSystem(size: 18, weight: .semibold))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    Text("처리 오류")
                        .font(.gwaTopSystem(size: 11, weight: .semibold))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                }
            }
        } else {
            ZStack {
                GwaTopHomeTheme.background.opacity(0.7)
                VStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(GwaTopHomeTheme.primary)
                    Text("처리 중")
                        .font(.gwaTopSystem(size: 11, weight: .semibold))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                }
            }
        }
    }

    // MARK: - Small components

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.gwaTopSystem(size: 12, weight: .bold))
            .foregroundStyle(GwaTopHomeTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private func typeBadge(_ type: String) -> some View {
        Text(type.uppercased())
            .font(.gwaTopSystem(size: 10, weight: .bold))
            .foregroundStyle(GwaTopHomeTheme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(GwaTopHomeTheme.surfaceMute)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func weekChip(_ f: GwaTopFileSummary) -> some View {
        let label: String = {
            if let w = f.week { return "\(w)주차" }
            switch f.status {
            case "unclassified": return "미분류"
            case "classifying":  return "분류 중"
            case "extracted":    return "분류 대기"
            default:             return "분류 대기"
            }
        }()
        return Text(label)
            .font(.gwaTopSystem(size: 10, weight: .bold))
            .foregroundStyle(GwaTopHomeTheme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(GwaTopHomeTheme.surfaceMute)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    /// 준비 완료 / 처리 중 / 실패 (강의계획서 행에서 사용).
    @ViewBuilder
    private func statusIcon(_ f: GwaTopFileSummary) -> some View {
        if Self.readyStatuses.contains(f.status) {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.gwaTopSystem(size: 10, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
                Text("준비 완료")
                    .font(.gwaTopSystem(size: 11, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.primary)
            }
        } else if f.status == "failed" {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.gwaTopSystem(size: 10, weight: .semibold))
                Text("오류")
                    .font(.gwaTopSystem(size: 11, weight: .semibold))
            }
            .foregroundStyle(GwaTopHomeTheme.danger)
        } else {
            HStack(spacing: 3) {
                ProgressView().scaleEffect(0.55)
                Text("처리 중")
                    .font(.gwaTopSystem(size: 11, weight: .semibold))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            }
        }
    }

    // MARK: - Derived

    private var syllabusFiles: [GwaTopFileSummary] {
        files.filter { $0.isSyllabus }
    }

    /// 강의자료 — 주차 오름차순(미분류는 마지막), 같은 주차 내에선 최신 업로드 먼저.
    private var materialFiles: [GwaTopFileSummary] {
        files.filter { !$0.isSyllabus }.sorted { a, b in
            let wa = a.week ?? Int.max
            let wb = b.week ?? Int.max
            if wa != wb { return wa < wb }
            return a.createdAt > b.createdAt
        }
    }

    /// 백엔드 최종(준비 완료) 상태. 자료는 classified/unclassified, 강의계획서는 parsed.
    private static let readyStatuses: Set<String> = [
        "classified", "unclassified", "parsed", "done"
    ]

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일"
        return f
    }()

    private func icon(for fileType: String) -> String {
        switch fileType {
        case "pdf":   return "doc.richtext"
        case "pptx":  return "rectangle.stack"
        case "docx":  return "doc.text"
        case "image": return "photo"
        default:      return "doc"
        }
    }

    /// 백엔드 요일 코드(MON…SUN) → 한글 1글자.
    private static func dayLabel(_ day: String) -> String {
        switch day.uppercased() {
        case "MON": return "월"
        case "TUE": return "화"
        case "WED": return "수"
        case "THU": return "목"
        case "FRI": return "금"
        case "SAT": return "토"
        case "SUN": return "일"
        default:    return day
        }
    }
}
