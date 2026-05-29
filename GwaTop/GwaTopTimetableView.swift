//
//  GwaTopTimetableView.swift
//  GwaTop
//
//  주간 시간표 — Course.schedule(요일/시작/종료)을 기반으로 그리드를 그린다.
//  강의계획서 파싱 결과(class_times)가 백엔드 Course.schedule 에 저장되어 있어야 채워진다.
//

import SwiftUI

struct GwaTopTimetableView: View {
    let courses: [GwaTopCourseDTO]
    /// 시간표 블록을 탭했을 때 호출 — 부모가 정보/수정 시트를 띄움.
    var onSelectCourse: ((GwaTopCourseDTO) -> Void)? = nil

    private let dayOrder: [String] = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
    private let dayLabel: [String: String] = [
        "MON": "월", "TUE": "화", "WED": "수", "THU": "목",
        "FRI": "금", "SAT": "토", "SUN": "일",
    ]

    // 그리드 측정값 — 1시간 = hourHeight pt.
    private let hourHeight: CGFloat = 56
    private let timeColumnWidth: CGFloat = 44
    private let headerHeight: CGFloat = 36

    var body: some View {
        let blocks = computeBlocks()
        let days = displayDays(from: blocks)
        let (startHour, endHour) = displayRange(from: blocks)

        VStack(spacing: 12) {
            // 시간표 추가 버튼은 캘린더 탭 공용 FAB 으로 통합됨 — 인라인 버튼 제거.

            if blocks.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    grid(blocks: blocks, days: days, startHour: startHour, endHour: endHour)
                }
                .padding(.horizontal, 2)
            }
            legend
        }
    }

    // MARK: - Grid

    private func grid(
        blocks: [TimetableBlock],
        days: [String],
        startHour: Int,
        endHour: Int
    ) -> some View {
        let hours = endHour - startHour
        let totalHeight = CGFloat(hours) * hourHeight

        return HStack(alignment: .top, spacing: 0) {
            // 좌측 시간 컬럼
            VStack(spacing: 0) {
                Color.clear.frame(height: headerHeight)
                ForEach(0..<hours, id: \.self) { i in
                    HStack {
                        Text("\(startHour + i):00")
                            .font(.gwaTopSystem(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, -6)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.trailing, 6)
                        Spacer(minLength: 0)
                    }
                    .frame(height: hourHeight, alignment: .top)
                }
            }
            .frame(width: timeColumnWidth)

            // 각 요일 컬럼
            ForEach(days, id: \.self) { day in
                dayColumn(
                    day: day,
                    blocks: blocks.filter { $0.day == day },
                    startHour: startHour,
                    totalHeight: totalHeight
                )
            }
        }
        .padding(.vertical, 8)
    }

    private func dayColumn(
        day: String,
        blocks: [TimetableBlock],
        startHour: Int,
        totalHeight: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            Text(dayLabel[day] ?? day)
                .font(.gwaTopSystem(size: 12, weight: .bold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: headerHeight)
                .background(GwaTopHomeTheme.surfaceMute)

            ZStack(alignment: .topLeading) {
                // 시간 격자 가로선
                VStack(spacing: 0) {
                    ForEach(0..<Int(totalHeight / hourHeight), id: \.self) { _ in
                        Divider()
                            .frame(maxWidth: .infinity)
                        Spacer(minLength: 0)
                            .frame(height: hourHeight - 0.5)
                    }
                }
                .frame(maxWidth: .infinity)

                // 강의 블록
                ForEach(blocks) { block in
                    let y = CGFloat(block.startMin - startHour * 60) * (hourHeight / 60)
                    let h = max(CGFloat(block.endMin - block.startMin) * (hourHeight / 60), 20)
                    courseBlock(block)
                        .frame(maxWidth: .infinity)
                        .frame(height: h)
                        .offset(y: y)
                        .padding(.horizontal, 2)
                }
            }
            .frame(height: totalHeight)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .overlay(
            Rectangle()
                .stroke(GwaTopHomeTheme.line, lineWidth: 0.5)
        )
    }

    private func courseBlock(_ block: TimetableBlock) -> some View {
        let color = block.course.color.map(Color.gwaTopHex) ?? GwaTopHomeTheme.primary
        // 슬롯(요일)별 강의실 우선, 없으면 과목 전체 강의실로 폴백.
        let slotRoom = block.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let location = slotRoom.isEmpty
            ? (block.course.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : slotRoom
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(block.course.name)
                .font(.gwaTopSystem(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if let prof = block.course.professor, !prof.isEmpty {
                Text(prof)
                    .font(.gwaTopSystem(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            // 강의실 — 블록 하단. 핀 아이콘 + 텍스트로 시각적으로 한 줄에 압축.
            // 짧은 블록(30분짜리)에선 Spacer 가 먼저 collapse 되고 location 만 남음.
            if !location.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.gwaTopSystem(size: 8, weight: .bold))
                    Text(location)
                        .font(.gwaTopSystem(size: 9, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(.white.opacity(0.9))
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(color.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        // 탭 콜백이 있으면 버튼으로 감싸 클릭 가능. 없으면 그냥 표시 (이전 동작 유지).
        return Group {
            if let cb = onSelectCourse {
                Button {
                    cb(block.course)
                } label: { content }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    // MARK: - Legend

    private var legend: some View {
        let withSchedule = courses.filter { ($0.schedule ?? []).isEmpty == false }
        guard withSchedule.isEmpty == false else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                Text("과목")
                    .font(.gwaTopSystem(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                FlowHStack(spacing: 8, runSpacing: 6) {
                    ForEach(withSchedule) { c in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(c.color.map(Color.gwaTopHex) ?? GwaTopHomeTheme.primary)
                                .frame(width: 8, height: 8)
                            Text(c.name)
                                .font(.gwaTopSystem(size: 11, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(GwaTopHomeTheme.chipFill)
                        .clipShape(Capsule())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.day.timeline.left")
                .font(.gwaTopSystem(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("등록된 시간표가 아직 없어요")
                .font(.gwaTopSystem(size: 15, weight: .bold))
                .foregroundStyle(.primary)
            Text("강의계획서를 업로드하면 강의 시간이 자동으로 채워져요.")
                .font(.gwaTopSystem(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Data shaping

    private func computeBlocks() -> [TimetableBlock] {
        courses.flatMap { c -> [TimetableBlock] in
            (c.schedule ?? []).compactMap { ct -> TimetableBlock? in
                guard
                    let start = Self.minutes(from: ct.startTime),
                    let end = Self.minutes(from: ct.endTime),
                    end > start
                else { return nil }
                return TimetableBlock(
                    course: c,
                    day: ct.day.uppercased(),
                    startMin: start,
                    endMin: end,
                    location: ct.location
                )
            }
        }
    }

    private func displayDays(from blocks: [TimetableBlock]) -> [String] {
        let used = Set(blocks.map { $0.day })
        var days: [String] = ["MON", "TUE", "WED", "THU", "FRI"]
        if used.contains("SAT") { days.append("SAT") }
        if used.contains("SUN") { days.append("SUN") }
        return days
    }

    private func displayRange(from blocks: [TimetableBlock]) -> (Int, Int) {
        guard
            let minStart = blocks.map({ $0.startMin }).min(),
            let maxEnd = blocks.map({ $0.endMin }).max()
        else {
            return (9, 18)
        }
        let startHour = min(9, max(0, minStart / 60))
        let endHour = max(18, min(24, (maxEnd + 59) / 60))
        return (startHour, endHour)
    }

    static func minutes(from hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              0 <= h, h < 24,
              0 <= m, m < 60
        else { return nil }
        return h * 60 + m
    }
}

// MARK: - Block model

private struct TimetableBlock: Identifiable {
    let id = UUID()
    let course: GwaTopCourseDTO
    let day: String
    let startMin: Int
    let endMin: Int
    /// 이 슬롯(요일)의 강의실. 비어 있으면 표시 시 course.location 으로 폴백.
    let location: String?
}

// MARK: - 간단한 FlowHStack (Legend 줄바꿈)

struct FlowHStack<Content: View>: View {
    let spacing: CGFloat
    let runSpacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        // 단순 fallback — SwiftUI 자체 Layout API 사용 (iOS 16+)
        FlowLayout(spacing: spacing, runSpacing: runSpacing) {
            content()
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat
    var runSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth {
                totalHeight += rowHeight + runSpacing
                rowWidth = size.width + spacing
                rowHeight = size.height
            } else {
                rowWidth += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + runSpacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
