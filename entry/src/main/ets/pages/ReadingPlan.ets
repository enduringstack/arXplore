import { router } from '@kit.ArkUI';
import { localChatModel } from '@kit.DataAugmentationKit';
import { fileIo } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { Paper, ReadingPlan, PLAN_UNREAD, PLAN_READING, PLAN_DONE } from '../model/DataModels';
import { CloudLLMService } from '../service/CloudLLMService';
import { PreferencesUtil } from '../common/PreferencesUtil';

const STATUS_LABELS: string[] = ['未读', '在读', '已读'];
const STATUS_COLORS: string[] = ['#86868B', '#007AFF', '#34C759'];
const PRIORITY_LABELS: string[] = ['普通', '重要', '紧急'];
const PRIORITY_COLORS: string[] = ['#C7C7CC', '#FF9500', '#FF3B30'];

@Component
export struct ReadingPlanPage {
  @State papers: Paper[] = [];
  @State plans: Map<string, ReadingPlan> = new Map();
  @State progressMap: Map<string, number> = new Map();
  @State currentTab: number = -1; // -1=全部, 0=未读, 1=在读, 2=已读
  @State editingPaperId: string = '';
  @State editPlan: ReadingPlan | null = null;
  @State editNotes: string = '';
  @State showEditor: boolean = false;
  @State llmInited: boolean = false;
  @State aiGenerating: boolean = false;
  @State compareMode: boolean = false;
  @State compareSelection: string[] = [];
  @State compareResult: string = '';
  @State showCompare: boolean = false;
  @State compareLoading: boolean = false;
  @State toastMsg: string = '';
  @State readingStreak: number = 0;
  @State streakDays: number = 0;
  @State longestStreak: number = 0;
  @State todayCompleted: boolean = false;
  private toastTimer: number = 0;

  aboutToAppear(): void {
    this.loadData();
    this.initLlm();
    this.loadStreak();
  }

  async initLlm(): Promise<void> {
    try { this.llmInited = await localChatModel.init(); } catch (_) { this.llmInited = false; }
  }

  onPageShow(): void {
    this.loadData();
    this.loadStreak();
  }

  private async loadStreak(): Promise<void> {
    const lastReadDate = await PreferencesUtil.get('last_read_date', '') as string;
    const streak = await PreferencesUtil.get('streak_days', 0) as number;
    const longest = await PreferencesUtil.get('longest_streak', 0) as number;

    const today = new Date();
    const todayStr = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
    const yesterday = new Date(today);
    yesterday.setDate(yesterday.getDate() - 1);
    const yesterdayStr = `${yesterday.getFullYear()}-${String(yesterday.getMonth() + 1).padStart(2, '0')}-${String(yesterday.getDate()).padStart(2, '0')}`;

    if (lastReadDate === todayStr) {
      // 今天已读
      this.streakDays = streak;
      this.todayCompleted = true;
    } else if (lastReadDate === yesterdayStr) {
      // 昨天读了，streak继续
      this.streakDays = streak;
      this.todayCompleted = false;
    } else {
      // streak断了
      this.streakDays = 0;
      this.todayCompleted = false;
    }
    this.longestStreak = longest;
  }

  private async recordReading(): Promise<void> {
    const today = new Date();
    const todayStr = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
    const lastReadDate = await PreferencesUtil.get('last_read_date', '') as string;

    if (lastReadDate !== todayStr) {
      const yesterday = new Date(today);
      yesterday.setDate(yesterday.getDate() - 1);
      const yesterdayStr = `${yesterday.getFullYear()}-${String(yesterday.getMonth() + 1).padStart(2, '0')}-${String(yesterday.getDate()).padStart(2, '0')}`;

      if (lastReadDate === yesterdayStr) {
        this.streakDays += 1;
      } else {
        this.streakDays = 1;
      }

      this.todayCompleted = true;
      if (this.streakDays > this.longestStreak) {
        this.longestStreak = this.streakDays;
        await PreferencesUtil.put('longest_streak', this.longestStreak);
      }
      await PreferencesUtil.put('streak_days', this.streakDays);
      await PreferencesUtil.put('last_read_date', todayStr);
      this.checkMilestone();
    }
  }

  private checkMilestone(): void {
    const milestones: number[] = [7, 30, 100, 365];
    if (milestones.includes(this.streakDays)) {
      this.showToast(`恭喜！连续阅读 ${this.streakDays} 天！`);
    }
  }

  async loadData(): Promise<void> {
    await PreferencesUtil.init(getContext(this));
    this.papers = PreferencesUtil.getFavoritePapers();
    const allPlans = PreferencesUtil.getPlans();
    const map = new Map<string, ReadingPlan>();
    for (const p of allPlans) { map.set(p.paperId, p); }
    // Auto-create plans for favorites without one
    for (const paper of this.papers) {
      if (!map.has(paper.id)) {
        const plan = PreferencesUtil.createDefaultPlan(paper.id);
        PreferencesUtil.savePlan(plan);
        map.set(paper.id, plan);
      }
    }
    // Load progress + auto-complete 100% papers
    const pm = new Map<string, number>();
    for (const paper of this.papers) {
      const prog = await PreferencesUtil.getReadingProgress(paper.id);
      pm.set(paper.id, prog);
      // Auto mark as "已读" if progress is 100%
      if (prog >= 100) {
        const plan = map.get(paper.id);
        if (plan && plan.status === PLAN_READING) {
          plan.status = PLAN_DONE;
          if (!plan.completedAt) plan.completedAt = this.today();
          PreferencesUtil.savePlan(plan);
          this.recordReading();
        }
      }
    }
    this.plans = map;
    this.progressMap = pm;
    this.readingStreak = await PreferencesUtil.getReadingStreak();
  }

  filteredPapers(): Paper[] {
    if (this.currentTab === -1) return this.papers;
    return this.papers.filter(p => {
      const plan = this.plans.get(p.id);
      return plan ? plan.status === this.currentTab : this.currentTab === PLAN_UNREAD;
    });
  }

  stats(): number[] {
    let unread = 0, reading = 0, done = 0;
    for (const paper of this.papers) {
      const plan = this.plans.get(paper.id);
      if (!plan || plan.status === PLAN_UNREAD) unread++;
      else if (plan.status === PLAN_READING) reading++;
      else done++;
    }
    return [unread, reading, done];
  }

  today(): string {
    const d = new Date();
    const y = d.getFullYear();
    const m = (d.getMonth() + 1).toString().padStart(2, '0');
    const dd = d.getDate().toString().padStart(2, '0');
    return `${y}-${m}-${dd}`;
  }

  clonePlan(p: ReadingPlan): ReadingPlan {
    return {
      paperId: p.paperId, status: p.status, priority: p.priority,
      deadline: p.deadline, notes: p.notes, startedAt: p.startedAt, completedAt: p.completedAt
    };
  }

  openEdit(paper: Paper): void {
    this.editingPaperId = paper.id;
    let plan = this.plans.get(paper.id);
    if (!plan) {
      plan = PreferencesUtil.createDefaultPlan(paper.id);
    }
    this.editPlan = {
      paperId: plan.paperId,
      status: plan.status,
      priority: plan.priority,
      deadline: plan.deadline,
      notes: plan.notes,
      startedAt: plan.startedAt,
      completedAt: plan.completedAt
    };
    this.editNotes = plan.notes;
    this.showEditor = true;
  }

  saveEdit(): void {
    if (!this.editPlan) return;
    this.editPlan.notes = this.editNotes;
    PreferencesUtil.savePlan(this.editPlan);
    this.plans.set(this.editPlan.paperId, this.editPlan);
    // Force reactivity
    this.plans = new Map(this.plans);
    this.showEditor = false;
  }

  setStatus(s: number): void {
    if (!this.editPlan) return;
    this.editPlan.status = s;
    if (s === PLAN_READING && !this.editPlan.startedAt) {
      this.editPlan.startedAt = this.today();
    }
    if (s === PLAN_DONE && !this.editPlan.completedAt) {
      this.editPlan.completedAt = this.today();
      this.recordReading();
    }
    // Force re-render
    this.editPlan = this.clonePlan(this.editPlan!);
  }

  setPriority(p: number): void {
    if (!this.editPlan) return;
    this.editPlan.priority = p;
    this.editPlan = this.clonePlan(this.editPlan!);
  }

  async generateAiNotes(): Promise<void> {
    if (!this.editPlan || this.aiGenerating) return;
    const paper = this.papers.find(p => p.id === this.editPlan!.paperId);
    if (!paper) return;

    this.aiGenerating = true;
    const prompt = `请用中文为以下论文生成一份读后感/笔记模板，包括：
1. 核心贡献（2-3句）
2. 方法概述（2-3句）
3. 关键发现
4. 与我的研究方向的关联（留空让用户填写）
5. 待深入阅读的部分（留空让用户填写）

论文标题：${paper.title}
摘要：${paper.summary}`;

    if (this.llmInited) {
      const question: localChatModel.QuestionInfo = { questionId: Date.now(), content: prompt };
      try {
        await localChatModel.chat(question, { isStream: true } as localChatModel.Config,
          (err, answer: localChatModel.Answer) => {
            if (err) { this.aiGenerating = false; return; }
            this.editNotes += answer.content;
            if (answer.isFinished) this.aiGenerating = false;
          });
      } catch (_) {
        this.editNotes += '\n\n[端侧 AI 生成失败]';
        this.aiGenerating = false;
      }
    } else {
      try {
        const result = await CloudLLMService.chat(prompt);
        this.editNotes += result;
      } catch (_) {
        this.editNotes += '\n\n[云端 AI 请求失败]';
      }
      this.aiGenerating = false;
    }
  }

  toggleCompareSelect(paperId: string): void {
    if (this.compareSelection.includes(paperId)) {
      this.compareSelection = this.compareSelection.filter(id => id !== paperId);
    } else if (this.compareSelection.length < 2) {
      this.compareSelection = [...this.compareSelection, paperId];
    }
    if (this.compareSelection.length === 2) {
      this.doCompare();
    }
  }

  async doCompare(): Promise<void> {
    const p1 = this.papers.find(p => p.id === this.compareSelection[0]);
    const p2 = this.papers.find(p => p.id === this.compareSelection[1]);
    if (!p1 || !p2) return;
    this.compareLoading = true;
    this.compareResult = '';
    this.showCompare = true;
    this.compareMode = false;

    const prompt = `请用中文对比分析以下两篇论文的异同，包括：方法差异、研究角度、各自优势。\n\n论文A：${p1.title}\n摘要：${p1.summary.substring(0, 300)}\n\n论文B：${p2.title}\n摘要：${p2.summary.substring(0, 300)}`;
    if (this.llmInited) {
      const question: localChatModel.QuestionInfo = { questionId: Date.now(), content: prompt };
      try {
        await localChatModel.chat(question, { isStream: true } as localChatModel.Config,
          (err, answer: localChatModel.Answer) => {
            if (err) { this.compareResult = '对比分析失败'; this.compareLoading = false; return; }
            this.compareResult += answer.content;
            if (answer.isFinished) this.compareLoading = false;
          });
      } catch (_) { this.compareResult = '对比分析失败'; this.compareLoading = false; }
    } else {
      try {
        this.compareResult = await CloudLLMService.chat(prompt);
      } catch (_) { this.compareResult = '云端 AI 请求失败'; }
      this.compareLoading = false;
    }
  }

  openPaperDetail(paper: Paper): void {
    // Auto mark as "在读" when opening
    const plan = this.plans.get(paper.id);
    if (plan && plan.status === PLAN_UNREAD) {
      plan.status = PLAN_READING;
      plan.startedAt = this.today();
      PreferencesUtil.savePlan(plan);
      this.plans = new Map(this.plans);
    }
    AppStorage.setOrCreate('selectedPaperJson', JSON.stringify(paper));
    router.pushUrl({ url: 'pages/PaperDetail' });
  }

  showToast(msg: string): void {
    this.toastMsg = msg;
    if (this.toastTimer > 0) clearTimeout(this.toastTimer);
    this.toastTimer = setTimeout(() => { this.toastMsg = ''; this.toastTimer = 0; }, 1500);
  }

  notesCount(): number {
    let count = 0;
    for (const paper of this.papers) {
      const plan = this.plans.get(paper.id);
      if (plan && plan.notes) count++;
    }
    return count;
  }

  completionRate(): number {
    if (this.papers.length === 0) return 0;
    return Math.round(this.stats()[2] / this.papers.length * 100);
  }

  overdueCount(): number {
    const td = this.today();
    let count = 0;
    for (const paper of this.papers) {
      const plan = this.plans.get(paper.id);
      if (plan && plan.deadline && plan.deadline < td && plan.status !== PLAN_DONE) count++;
    }
    return count;
  }

  async exportToClipboard(): Promise<void> {
    if (this.papers.length === 0) {
      this.showToast('暂无论文可导出');
      return;
    }
    let text = '# arXplore 阅读计划\n\n';
    const s = this.stats();
    text += `总计 ${this.papers.length} 篇 | 未读 ${s[0]} | 在读 ${s[1]} | 已读 ${s[2]}\n`;
    text += `完成率 ${this.completionRate()}%\n\n`;
    for (const paper of this.papers) {
      const plan = this.plans.get(paper.id);
      const prog = this.progressMap.get(paper.id) ?? 0;
      text += `## ${paper.title}\n`;
      text += `状态: ${STATUS_LABELS[plan?.status ?? 0]} | 进度: ${prog}%\n`;
      if (plan && plan.priority > 0) text += `优先级: ${PRIORITY_LABELS[plan.priority]}\n`;
      if (plan?.deadline) text += `截止: ${plan.deadline}\n`;
      text += `arXiv: ${paper.id}\n`;
      if (plan?.notes) text += `笔记: ${plan.notes}\n`;
      text += '\n';
    }
    const clipData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(clipData);
    this.showToast('计划已导出到剪贴板');
  }

  build() {
    Stack() {
      Column() {
        // Nav
        Row() {
          Text('阅读计划')
            .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#1D1D1F')
            .padding({ left: 16 })

          Blank()

          Text('导出')
            .fontSize(14).fontColor('#007AFF')
            .padding({ left: 8, right: 4, top: 4, bottom: 4 })
            .onClick(() => { this.exportToClipboard(); })

          Text(this.compareMode ? '取消' : '对比')
            .fontSize(14).fontColor('#007AFF')
            .padding({ left: 8, right: 16, top: 4, bottom: 4 })
            .onClick(() => {
              this.compareMode = !this.compareMode;
              this.compareSelection = [];
            })
        }
        .width('100%').height(44).alignItems(VerticalAlign.Center)
        .backgroundColor('#FFFFFF')

        // Streak Card
        this.StreakCard()

        // Stats cards
        Row({ space: 10 }) {
          this.StatCard('未读', this.stats()[0], '#86868B', '#FFFFFF')
          this.StatCard('在读', this.stats()[1], '#007AFF', '#E8F3FF')
          this.StatCard('已读', this.stats()[2], '#34C759', '#F0FFF4')
        }
        .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 4 })

        // Completion info
        if (this.papers.length > 0) {
          Row() {
            Text(`完成率 ${this.completionRate()}%`)
              .fontSize(12).fontColor(this.completionRate() > 0 ? '#34C759' : '#AEAEB2')

            if (this.notesCount() > 0) {
              Text(`  ·  ${this.notesCount()} 篇有笔记`)
                .fontSize(12).fontColor('#FF9500')
            }

            if (this.overdueCount() > 0) {
              Text(`  ·  ${this.overdueCount()} 篇已逾期`)
                .fontSize(12).fontColor('#FF3B30')
            }

            Blank()
          }
          .width('100%').padding({ left: 16, right: 16, top: 6, bottom: 4 })
        }

        // Tabs
        Row({ space: 8 }) {
          this.TabChip('全部', -1)
          this.TabChip('未读', 0)
          this.TabChip('在读', 1)
          this.TabChip('已读', 2)
        }
        .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 8 })

        // List
        if (this.filteredPapers().length === 0) {
          if (this.papers.length === 0) {
            // 阅读计划为空
            Column() {
              Text('📚')
                .fontSize(64)
              Text('还没有阅读计划')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1D1D1F')
                .margin({ top: 16 })
              Text('收藏论文后可以添加到阅读计划')
                .fontSize(14)
                .fontColor('#86868B')
                .margin({ top: 8 })
            }
            .width('100%')
            .padding({ top: 120 })
            .alignItems(HorizontalAlign.Center)
            .layoutWeight(1)
          } else {
            // 当前筛选分类下无论文
            Column() {
              Text('该分类下暂无论文')
                .fontSize(14)
                .fontColor('#86868B')
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          }
        } else {
          List({ space: 10 }) {
            ForEach(this.filteredPapers(), (paper: Paper) => {
              ListItem() { this.PlanCard(paper) }
                .padding({ left: 16, right: 16 })
            }, (paper: Paper) => paper.id)
          }
          .width('100%').layoutWeight(1)
          .padding({ top: 4, bottom: 16 })
          .divider({ strokeWidth: 0 })
        }
      }
      .width('100%').height('100%').backgroundColor('#F2F2F7')

      // Editor sheet
      if (this.showEditor) { this.EditorSheet() }
      if (this.showCompare) { this.CompareSheet() }

      // Toast
      if (this.toastMsg) {
        Column() {
          Blank()
          Text(this.toastMsg)
            .fontSize(14).fontColor('#FFFFFF')
            .backgroundColor('#1D1D1FCC')
            .borderRadius(20)
            .padding({ left: 20, right: 20, top: 10, bottom: 10 })
            .margin({ bottom: 120 })
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.End).alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%').height('100%')
  }

  @Builder
  StreakCard() {
    Row() {
      // 火焰图标 + 天数
      Column() {
        Text('🔥')
          .fontSize(36)
        Text(`${this.streakDays}`)
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1D1D1F')
          .margin({ top: 4 })
        Text('天连续阅读')
          .fontSize(12)
          .fontColor('#86868B')
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Center)
      .layoutWeight(1)

      // 分割线
      Column()
        .width(0.5)
        .height(50)
        .backgroundColor('#E5E5EA')

      // 最长记录
      Column() {
        Text('🏆')
          .fontSize(20)
        Text(`${this.longestStreak}`)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1D1D1F')
          .margin({ top: 4 })
        Text('最长纪录')
          .fontSize(12)
          .fontColor('#86868B')
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Center)
      .layoutWeight(1)

      // 分割线
      Column()
        .width(0.5)
        .height(50)
        .backgroundColor('#E5E5EA')

      // 今日状态
      Column() {
        Text(this.todayCompleted ? '✅' : '📖')
          .fontSize(20)
        Text(this.todayCompleted ? '已完成' : '待阅读')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.todayCompleted ? '#34C759' : '#FF9500')
          .margin({ top: 4 })
        Text('今日目标')
          .fontSize(12)
          .fontColor('#86868B')
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Center)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 20, bottom: 20, left: 16, right: 16 })
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
    .shadow({ radius: 8, color: '#0A000000', offsetX: 0, offsetY: 2 })
    .margin({ left: 16, right: 16, top: 12, bottom: 8 })
  }

  @Builder
  StatCard(label: string, count: number, color: string, bgColor: string) {
    Column({ space: 4 }) {
      Text(count.toString())
        .fontSize(28).fontWeight(FontWeight.Bold).fontColor(color)
      Text(label)
        .fontSize(12).fontColor('#86868B')
    }
    .layoutWeight(1)
    .padding({ top: 14, bottom: 14 })
    .backgroundColor(bgColor)
    .borderRadius(12)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  TabChip(label: string, tab: number) {
    Text(label)
      .fontSize(13)
      .fontColor(this.currentTab === tab ? '#FFFFFF' : '#3C3C43')
      .backgroundColor(this.currentTab === tab ? '#007AFF' : '#FFFFFF')
      .borderRadius(16)
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .onClick(() => { this.currentTab = tab; })
  }

  @Builder
  PlanCard(paper: Paper) {
    Column({ space: 8 }) {
      Row() {
        if (this.compareMode) {
          // Compare checkbox
          Circle()
            .width(20).height(20)
            .fill(this.compareSelection.includes(paper.id) ? '#007AFF' : '#00000000')
            .stroke(this.compareSelection.includes(paper.id) ? '#007AFF' : '#C7C7CC')
            .strokeWidth(2)
            .margin({ right: 10 })
        } else {
          // Status dot
          Circle()
            .width(8).height(8)
            .fill(STATUS_COLORS[this.plans.get(paper.id)?.status ?? 0])
            .margin({ right: 8 })
        }

        Text(paper.title)
          .fontSize(15).fontWeight(FontWeight.Medium).fontColor('#1D1D1F')
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        // Priority tag
        if ((this.plans.get(paper.id)?.priority ?? 0) > 0) {
          Text(PRIORITY_LABELS[this.plans.get(paper.id)?.priority ?? 0])
            .fontSize(10)
            .fontColor(PRIORITY_COLORS[this.plans.get(paper.id)?.priority ?? 0])
            .backgroundColor(
              (this.plans.get(paper.id)?.priority ?? 0) === 2 ? '#FFF1F0' : '#FFF8E8'
            )
            .borderRadius(4)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ left: 8 })
        }
      }
      .width('100%').alignItems(VerticalAlign.Center)

      // Progress bar
      Row() {
        Progress({ value: this.progressMap.get(paper.id) ?? 0, total: 100 })
          .layoutWeight(1).height(3)
          .color('#007AFF').backgroundColor('#F2F2F7').borderRadius(1.5)

        Text(`${this.progressMap.get(paper.id) ?? 0}%`)
          .fontSize(11).fontColor('#AEAEB2').margin({ left: 8 }).width(36)
      }
      .width('100%').alignItems(VerticalAlign.Center)

      // Bottom row: deadline + status + edit
      Row() {
        Text(STATUS_LABELS[this.plans.get(paper.id)?.status ?? 0])
          .fontSize(11)
          .fontColor(STATUS_COLORS[this.plans.get(paper.id)?.status ?? 0])
          .fontWeight(FontWeight.Medium)

        if (this.plans.get(paper.id)?.deadline) {
          Text(`  ·  截止 ${this.plans.get(paper.id)!.deadline}`)
            .fontSize(11).fontColor('#86868B')
        }

        if (this.plans.get(paper.id)?.notes) {
          Text('  ·  有笔记')
            .fontSize(11).fontColor('#FF9500')
        }

        Blank()

        Text('编辑')
          .fontSize(12).fontColor('#007AFF')
          .onClick(() => { this.openEdit(paper); })
      }
      .width('100%').alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .shadow({ radius: 4, color: '#0D000000', offsetX: 0, offsetY: 2 })
    .onClick(() => {
      if (this.compareMode) { this.toggleCompareSelect(paper.id); }
      else { this.openPaperDetail(paper); }
    })
  }

  @Builder
  EditorSheet() {
    Column() {
      Blank()

      Column() {
        // Handle
        Column()
          .width(36).height(4).borderRadius(2).backgroundColor('#D1D1D6')
          .margin({ top: 8, bottom: 12 })

        // Header
        Row() {
          Text('编辑计划')
            .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#000000')
          Blank()
          Text('保存')
            .fontSize(16).fontColor('#007AFF').fontWeight(FontWeight.Medium)
            .onClick(() => { this.saveEdit(); })
        }
        .width('100%').padding({ left: 24, right: 24, bottom: 12 })

        Divider().color('#E5E5EA')

        Scroll() {
          Column({ space: 20 }) {
            // Status section
            Column({ space: 10 }) {
              Text('阅读状态')
                .fontSize(13).fontColor('#86868B').fontWeight(FontWeight.Medium).width('100%')

              Row({ space: 10 }) {
                ForEach([0, 1, 2], (s: number) => {
                  Text(STATUS_LABELS[s])
                    .fontSize(14)
                    .fontColor(this.editPlan?.status === s ? '#FFFFFF' : STATUS_COLORS[s])
                    .backgroundColor(this.editPlan?.status === s ? STATUS_COLORS[s] : '#F2F2F7')
                    .borderRadius(20)
                    .padding({ left: 18, right: 18, top: 8, bottom: 8 })
                    .onClick(() => { this.setStatus(s); })
                }, (s: number) => s.toString())
              }
            }

            // Priority section
            Column({ space: 10 }) {
              Text('优先级')
                .fontSize(13).fontColor('#86868B').fontWeight(FontWeight.Medium).width('100%')

              Row({ space: 10 }) {
                ForEach([0, 1, 2], (p: number) => {
                  Text(PRIORITY_LABELS[p])
                    .fontSize(14)
                    .fontColor(this.editPlan?.priority === p ? '#FFFFFF' : PRIORITY_COLORS[p])
                    .backgroundColor(this.editPlan?.priority === p ? PRIORITY_COLORS[p] : '#F2F2F7')
                    .borderRadius(20)
                    .padding({ left: 18, right: 18, top: 8, bottom: 8 })
                    .onClick(() => { this.setPriority(p); })
                }, (p: number) => p.toString())
              }
            }

            // Deadline
            Column({ space: 10 }) {
              Text('计划截止日期')
                .fontSize(13).fontColor('#86868B').fontWeight(FontWeight.Medium).width('100%')

              Row({ space: 8 }) {
                Text(this.editPlan?.deadline ? this.editPlan.deadline : '点击选择日期')
                  .fontSize(15)
                  .fontColor(this.editPlan?.deadline ? '#1D1D1F' : '#C7C7CC')
                  .layoutWeight(1).height(40)
                  .backgroundColor('#F2F2F7').borderRadius(10)
                  .padding({ left: 12, right: 12 })
                  .textAlign(TextAlign.Start)
                  .onClick(() => {
                    DatePickerDialog.show({
                      start: new Date('2024-01-01'),
                      end: new Date('2030-12-31'),
                      selected: this.editPlan?.deadline ? new Date(this.editPlan.deadline) : new Date(),
                      onDateAccept: (value: Date) => {
                        if (this.editPlan) {
                          const y = value.getFullYear();
                          const m = (value.getMonth() + 1).toString().padStart(2, '0');
                          const d = value.getDate().toString().padStart(2, '0');
                          this.editPlan.deadline = `${y}-${m}-${d}`;
                          this.editPlan = this.clonePlan(this.editPlan);
                        }
                      }
                    });
                  })

                if (this.editPlan?.deadline) {
                  Text('清除').fontSize(13).fontColor('#FF3B30')
                    .onClick(() => { if (this.editPlan) { this.editPlan.deadline = ''; this.editPlan = this.clonePlan(this.editPlan!); } })
                }
              }
            }

            // Time info
            if (this.editPlan?.startedAt || this.editPlan?.completedAt) {
              Column({ space: 4 }) {
                if (this.editPlan?.startedAt) {
                  Text(`开始阅读：${this.editPlan.startedAt}`)
                    .fontSize(12).fontColor('#AEAEB2').width('100%')
                }
                if (this.editPlan?.completedAt) {
                  Text(`完成阅读：${this.editPlan.completedAt}`)
                    .fontSize(12).fontColor('#34C759').width('100%')
                }
              }
            }

            // Notes
            Column({ space: 10 }) {
              Row() {
                Text('读后感 / 笔记')
                  .fontSize(13).fontColor('#86868B').fontWeight(FontWeight.Medium)

                Blank()

                if (this.aiGenerating) {
                  Row({ space: 6 }) {
                    LoadingProgress().width(14).height(14).color('#007AFF')
                    Text('生成中...').fontSize(12).fontColor('#007AFF')
                  }
                } else {
                  Text('AI 生成')
                    .fontSize(12)
                    .fontColor('#007AFF')
                    .fontWeight(FontWeight.Medium)
                    .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                    .borderRadius(12)
                    .border({ width: 1, color: '#007AFF', style: BorderStyle.Solid })
                    .onClick(() => { this.generateAiNotes(); })
                }
              }
              .width('100%')

              TextArea({ placeholder: '写下你的读后感、关键发现、灵感...', text: this.editNotes })
                .width('100%')
                .height(180)
                .fontSize(15)
                .backgroundColor('#F2F2F7')
                .borderRadius(12)
                .padding(12)
                .onChange((v: string) => { this.editNotes = v; })
            }

            Row().height(32)
          }
          .padding({ left: 24, right: 24, top: 20 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('70%')
      .backgroundColor('#FFFFFF')
      .borderRadius({ topLeft: 16, topRight: 16 })
      .shadow({ radius: 20, color: '#26000000', offsetX: 0, offsetY: -2 })
    }
    .width('100%').height('100%')
    .backgroundColor('#00000040')
  }

  @Builder
  CompareSheet() {
    Column() {
      Blank()
      Column() {
        Column().width(36).height(4).borderRadius(2).backgroundColor('#D1D1D6').margin({ top: 8, bottom: 12 })
        Row() {
          Text('论文对比')
            .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#000000')
          Blank()
          Text('关闭')
            .fontSize(16).fontColor('#007AFF').fontWeight(FontWeight.Medium)
            .onClick(() => { this.showCompare = false; this.compareSelection = []; })
        }
        .width('100%').padding({ left: 24, right: 24, bottom: 12 })
        Divider().color('#E5E5EA')
        Scroll() {
          Column() {
            if (this.compareLoading && this.compareResult.length === 0) {
              Row({ space: 8 }) {
                LoadingProgress().width(18).height(18).color('#007AFF')
                Text('正在分析...').fontSize(15).fontColor('#86868B')
              }.padding({ top: 24 }).justifyContent(FlexAlign.Center).width('100%')
            } else {
              Text(this.compareResult)
                .fontSize(16).fontColor('#1D1D1F').lineHeight(26).width('100%').padding({ top: 20 })
              if (this.compareLoading) {
                LoadingProgress().width(14).height(14).color('#007AFF').margin({ top: 8 })
              }
            }
            Row().height(32)
          }.padding({ left: 24, right: 24 })
        }.layoutWeight(1).scrollBar(BarState.Off)
      }
      .width('100%').height('55%')
      .backgroundColor('#FFFFFF')
      .borderRadius({ topLeft: 16, topRight: 16 })
      .shadow({ radius: 20, color: '#26000000', offsetX: 0, offsetY: -2 })
    }
    .width('100%').height('100%')
    .backgroundColor('#00000040')
    .onClick(() => { this.showCompare = false; this.compareSelection = []; })
  }
}
