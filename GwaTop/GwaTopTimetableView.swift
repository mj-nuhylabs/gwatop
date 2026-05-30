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
    /// 겹침 해소 — 사용자가 둘 중 한 수업을 고르면 호출.
    /// (keep: 남길 수업, removeFrom: 충돌 슬롯을 뺄 수업, day/slotStart/slotEnd: 뺄 슬롯)
    var onResolveConflict: ((_ keep: GwaTopCourseDTO, _ removeFrom: GwaTopCourseDTO,
                             _ day: String, _ slotStartMin: Int, _ slotEndMin: Int) -> Void)? = nil

    /// 겹침 해소 확인 다이얼로그용 대기 상태.
    @State private var pendingResolution: PendingResolution? = nil

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
        let (conflicts, conflictKeys) = Self.computeConflicts(blocks)

        VStack(spacing: 12) {
            // 시간표 추가 버튼은 캘린더 탭 공용 FAB 으로 통합됨 — 인라인 버튼 제거.

            if !conflicts.isEmpty {
                conflictBanner(conflicts)
            }

            if blocks.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    grid(blocks: blocks, days: days, startHour: startHour, endHour: endHour,
                         conflictKeys: conflictKeys)
                }
                .padding(.horizontal, 2)
            }
            legend
        }
    }

    // MARK: - 시간 겹침 알림

    /// 겹치는 수업 쌍마다 "어떤 수업을 둘까요?" — 두 수업을 선택지로 보여준다.
    /// 한쪽을 고르면 그 수업만 시간표에 남고, 다른 수업의 충돌 슬롯은 제거된다.
    private func conflictBanner(_ conflicts: [TimetableConflict]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("시간이 겹치는 수업이 \(conflicts.count)개 있어요")
                    .font(.gwaTopSystem(size: 14, weight: .heavy))
            }
            .foregroundStyle(GwaTopHomeTheme.danger)

            ForEach(conflicts) { c in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(dayLabel[c.day] ?? c.day)요일 \(Self.hhmm(c.overlapStartMin))–\(Self.hhmm(c.overlapEndMin)) 겹침 · 둘 수업을 골라주세요")
                        .font(.gwaTopSystem(size: 11, weight: .semibold))
                        .foregroundStyle(GwaTopHomeTheme.textSecondary)
                    HStack(spacing: 8) {
                        // 왼쪽 수업 선택 → 오른쪽(courseB) 슬롯 제거
                        conflictChoice(
                            course: c.courseA,
                            startMin: c.aStartMin, endMin: c.aEndMin
                        ) {
                            pendingResolution = PendingResolution(
                                keep: c.courseA, removeFrom: c.courseB,
                                day: c.day, slotStartMin: c.bStartMin, slotEndMin: c.bEndMin
                            )
                        }
                        // 오른쪽 수업 선택 → 왼쪽(courseA) 슬롯 제거
                        conflictChoice(
                            course: c.courseB,
                            startMin: c.bStartMin, endMin: c.bEndMin
                        ) {
                            pendingResolution = PendingResolution(
                                keep: c.courseB, removeFrom: c.courseA,
                                day: c.day, slotStartMin: c.aStartMin, slotEndMin: c.aEndMin
                            )
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GwaTopHomeTheme.danger.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(GwaTopHomeTheme.danger.opacity(0.25), lineWidth: 1)
        )
        .confirmationDialog(
            "이 수업만 시간표에 둘까요?",
            isPresented: Binding(
                get: { pendingResolution != nil },
                set: { if !$0 { pendingResolution = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingResolution
        ) { p in
            Button("‘\(p.keep.name)’ 두기 (‘\(p.removeFrom.name)’ 이 시간 제거)", role: .destructive) {
                onResolveConflict?(p.keep, p.removeFrom, p.day, p.slotStartMin, p.slotEndMin)
                pendingResolution = nil
            }
            Button("취소", role: .cancel) { pendingResolution = nil }
        } message: { p in
            Text("‘\(p.removeFrom.name)’ 의 \(dayLabel[p.day] ?? p.day)요일 \(Self.hhmm(p.slotStartMin))–\(Self.hhmm(p.slotEndMin)) 수업이 시간표에서 빠집니다. (과목 자체는 유지)")
        }
    }

    /// 겹침 선택지 1개 — 과목 색 점 + 이름 + 시간. 탭하면 onTap.
    private func conflictChoice(
        course: GwaTopCourseDTO, startMin: Int, endMin: Int, onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(course.color.map(Color.gwaTopHex) ?? GwaTopHomeTheme.primary)
                        .frame(width: 8, height: 8)
                    Text(course.name)
                        .font(.gwaTopSystem(size: 12, weight: .bold))
                        .foregroundStyle(GwaTopHomeTheme.textPrimary)
                        .lineLimit(1)
                }
                Text("\(Self.hhmm(startMin))–\(Self.hhmm(endMin))")
                    .font(.gwaTopSystem(size: 10, weight: .medium))
                    .foregroundStyle(GwaTopHomeTheme.textSecondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GwaTopHomeTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(GwaTopHomeTheme.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// 같은 요일에 시간이 겹치는 (서로 다른 과목) 블록 쌍을 찾는다.
    /// 반환: (겹침 목록, 겹친 블록 식별키 집합) — 키는 그리드에서 빨간 테두리 칠하는 데 사용.
    private static func computeConflicts(
        _ blocks: [TimetableBlock]
    ) -> (conflicts: [TimetableConflict], keys: Set<String>) {
        var conflicts: [TimetableConflict] = []
        var keys: Set<String> = []
        let byDay = Dictionary(grouping: blocks, by: { $0.day })
        for (day, dayBlocks) in byDay {
            guard dayBlocks.count >= 2 else { continue }
            for i in 0..<dayBlocks.count {
                for j in (i + 1)..<dayBlocks.count {
                    let a = dayBlocks[i], b = dayBlocks[j]
                    // 같은 과목의 여러 슬롯끼리는 겹쳐도 정상 — 스킵.
                    if a.course.id == b.course.id { continue }
                    let overlapStart = max(a.startMin, b.startMin)
                    let overlapEnd = min(a.endMin, b.endMin)
                    if overlapStart < overlapEnd {
                        conflicts.append(TimetableConflict(
                            courseA: a.course, aStartMin: a.startMin, aEndMin: a.endMin,
                            courseB: b.course, bStartMin: b.startMin, bEndMin: b.endMin,
                            day: day,
                            overlapStartMin: overlapStart, overlapEndMin: overlapEnd
                        ))
                        keys.insert(blockKey(a))
                        keys.insert(blockKey(b))
                    }
                }
            }
        }
        // 보기 좋게 요일·시작 순으로 정렬.
        let order = ["MON": 0, "TUE": 1, "WED": 2, "THU": 3, "FRI": 4, "SAT": 5, "SUN": 6]
        conflicts.sort {
            (order[$0.day] ?? 9, $0.overlapStartMin) < (order[$1.day] ?? 9, $1.overlapStartMin)
        }
        return (conflicts, keys)
    }

    private static func blockKey(_ b: TimetableBlock) -> String {
        "\(b.course.id)|\(b.day)|\(b.startMin)|\(b.endMin)"
    }

    private static func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    // MARK: - Grid

    private func grid(
        blocks: [TimetableBlock],
        days: [String],
        startHour: Int,
        endHour: Int,
        conflictKeys: Set<String>
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
                    totalHeight: totalHeight,
                    conflictKeys: conflictKeys
                )
            }
        }
        .padding(.vertical, 8)
    }

    private func dayColumn(
        day: String,
        blocks: [TimetableBlock],
        startHour: Int,
        totalHeight: CGFloat,
        conflictKeys: Set<String>
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
                    courseBlock(block, isConflicting: conflictKeys.contains(Self.blockKey(block)))
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

    private func courseBlock(_ block: TimetableBlock, isConflicting: Bool = false) -> some View {
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
        // 시간이 겹치는 블록은 빨간 테두리 + 경고 아이콘으로 즉시 눈에 띄게.
        .overlay(alignment: .topTrailing) {
            if isConflicting {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.gwaTopSystem(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(GwaTopHomeTheme.danger)
                    .clipShape(Circle())
                    .offset(x: 3, y: -3)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isConflicting ? GwaTopHomeTheme.danger : .clear, lineWidth: 2)
        )

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

/// 같은 요일에 시간이 겹치는 두 과목 — 경고 배너에 한 줄씩 표시.
/// 각 과목의 충돌 슬롯 시간을 따로 들고 있어, 사용자가 한쪽을 고르면 다른 쪽 슬롯을 제거한다.
private struct TimetableConflict: Identifiable {
    let id = UUID()
    let courseA: GwaTopCourseDTO
    let aStartMin: Int
    let aEndMin: Int
    let courseB: GwaTopCourseDTO
    let bStartMin: Int
    let bEndMin: Int
    let day: String
    let overlapStartMin: Int
    let overlapEndMin: Int
}

/// 겹침 해소 확인 대기 — "removeFrom 의 day slot 을 뺄까요?" 다이얼로그에 쓰임.
private struct PendingResolution: Identifiable {
    let id = UUID()
    let keep: GwaTopCourseDTO
    let removeFrom: GwaTopCourseDTO
    let day: String
    let slotStartMin: Int
    let slotEndMin: Int
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
