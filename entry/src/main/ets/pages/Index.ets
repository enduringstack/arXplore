import { router } from '@kit.ArkUI';
import { Paper, Author, Category } from '../model/DataModels';
import { RecommendService } from '../service/RecommendService';
import { ArxivService } from '../service/ArxivService';
import { PreferencesUtil } from '../common/PreferencesUtil';
import { CloudLLMService } from '../service/CloudLLMService';

const FAVORITES_INDEX = -1;
const SEARCH_INDEX = -2;

interface ScoredPaper {
  paper: Paper;
  score: number;
}

@Component
export struct IndexPage {
  // 回调：通知父组件切换到指定 Tab（由 MainPage 注入）
  onSwitchTab?: (index: number) => void;
  @State categories: Category[] = [];
  @State currentIndex: number = 0;
  @State papers: Paper[] = [];
  @State isRefreshing: boolean = false;
  @State isLoading: boolean = true;
  private loadRequestId: number = 0;
  @State favoriteIds: string[] = [];
  @State errorMsg: string = '';
  @State cacheHint: string = '';
  private currentPage: number = 0;
  private pageSize: number = 20;
  @State hasMore: boolean = true;
  @State recommendedPapers: Paper[] = [];
  @State readPaperIds: string[] = [];

  // Search
  @State showSearchBar: boolean = false;
  @State searchKeyword: string = '';
  @State searchResultCount: number = 0;
  private savedIndex: number = 0;

  aboutToAppear(): void {
    this.initData();
  }

  onPageShow(): void {
    this.refreshState();
  }

  async initData(): Promise<void> {
    await PreferencesUtil.init(getContext(this));
    this.categories = await PreferencesUtil.getCategories();
    this.favoriteIds = PreferencesUtil.getFavoriteIds();
    await this.loadReadHistory();
    await this.loadPapers(false);
  }

  async refreshState(): Promise<void> {
    await PreferencesUtil.init(getContext(this));
    this.categories = await PreferencesUtil.getCategories();
    this.favoriteIds = PreferencesUtil.getFavoriteIds();
    if (this.currentIndex === FAVORITES_INDEX) {
      this.papers = PreferencesUtil.getFavoritePapers();
    }
  }

  formatCacheTime(query: string): string {
    const ts = ArxivService.getCacheTime(query);
    if (ts === 0) return '';
    const d = new Date(ts);
    const hh = d.getHours().toString().padStart(2, '0');
    const mm = d.getMinutes().toString().padStart(2, '0');
    return `缓存于 ${hh}:${mm}，下拉刷新获取最新`;
  }

  async loadPapers(forceRefresh: boolean): Promise<void> {
    const reqId = ++this.loadRequestId;
    this.errorMsg = '';
    this.currentPage = 0;
    this.hasMore = true;
    this.cacheHint = '';

    if (this.currentIndex === FAVORITES_INDEX) {
      this.papers = PreferencesUtil.getFavoritePapers();
      this.recommendedPapers = [];
      this.hasMore = false;
      this.isLoading = false;
      this.isRefreshing = false;
      return;
    }

    if (this.currentIndex < 0 || this.currentIndex >= this.categories.length) {
      this.papers = [];
      this.recommendedPapers = [];
      this.isLoading = false;
      this.isRefreshing = false;
      return;
    }

    const category = this.categories[this.currentIndex];
    const cachedTs = ArxivService.getCacheTime(category.query);
    const isFresh = cachedTs > 0 && Date.now() - cachedTs < 30 * 60 * 1000;

    if (forceRefresh || !isFresh) {
      this.papers = [];
    }

    this.isLoading = true;
    try {
      const result = await ArxivService.searchPapers(category.query, 0, this.pageSize, forceRefresh);
      if (reqId !== this.loadRequestId) return; // stale response
      this.papers = result;
      if (result.length < this.pageSize) this.hasMore = false;
      this.cacheHint = this.formatCacheTime(category.query);
      if (this.cacheHint) {
        setTimeout(() => { this.cacheHint = ''; }, 3000);
      }
      this.getRecommendations();
      this.generateTLDRs();
    } catch (_e) {
      if (reqId !== this.loadRequestId) return;
      this.errorMsg = '网络请求失败，请下拉刷新重试';
      this.papers = [];
      this.recommendedPapers = [];
    }
    this.isLoading = false;
    this.isRefreshing = false;
  }

  async loadMorePapers(): Promise<void> {
    if (!this.hasMore || this.isLoading || this.currentIndex === FAVORITES_INDEX || this.currentIndex === SEARCH_INDEX) return;
    if (this.currentIndex < 0 || this.currentIndex >= this.categories.length) return;

    this.currentPage++;
    const category = this.categories[this.currentIndex];
    try {
      const more = await ArxivService.searchPapers(
        category.query, this.currentPage * this.pageSize, this.pageSize, false);
      if (more.length < this.pageSize) {
        this.hasMore = false;
      }
      this.papers = [...this.papers, ...more];
    } catch (_e) {
      this.currentPage--;
    }
  }

  openSearchMode(): void {
    this.savedIndex = this.currentIndex;
    this.showSearchBar = true;
    this.searchKeyword = '';
  }

  closeSearchMode(): void {
    this.showSearchBar = false;
    this.searchKeyword = '';
    if (this.currentIndex === SEARCH_INDEX) {
      this.currentIndex = this.savedIndex;
      this.loadPapers(false);
    }
  }

  async doGlobalSearch(): Promise<void> {
    if (!this.searchKeyword.trim()) return;
    this.currentIndex = SEARCH_INDEX;
    this.isLoading = true;
    this.errorMsg = '';
    this.currentPage = 0;
    this.hasMore = true;
    this.cacheHint = '';
    this.papers = [];

    const query = `all:${this.searchKeyword.trim()}`;
    try {
      this.papers = await ArxivService.searchPapers(query, 0, this.pageSize, true, 'relevance');
      this.searchResultCount = this.papers.length;
      if (this.papers.length < this.pageSize) this.hasMore = false;
    } catch (_e) {
      this.errorMsg = '搜索失败，请重试';
    }
    this.isLoading = false;
  }

  async loadMoreSearchResults(): Promise<void> {
    if (!this.hasMore || this.isLoading || !this.searchKeyword.trim()) return;
    this.currentPage++;
    const query = `all:${this.searchKeyword.trim()}`;
    try {
      const more = await ArxivService.searchPapers(query, this.currentPage * this.pageSize, this.pageSize, false, 'relevance');
      if (more.length < this.pageSize) this.hasMore = false;
      this.papers = [...this.papers, ...more];
    } catch (_e) {
      this.currentPage--;
    }
  }

  // 论文加载后，异步为前10篇没有TLDR的论文生成TLDR
  private async generateTLDRs(): Promise<void> {
    const papers = this.papers.filter((p: Paper) => !p.tldr).slice(0, 10);
    for (const paper of papers) {
      try {
        const tldr = await CloudLLMService.generateTLDR(paper.title, paper.summary);
        if (tldr && !tldr.startsWith('请求失败') && !tldr.startsWith('云端')) {
          paper.tldr = tldr;
          // 触发UI更新
          this.papers = [...this.papers];
        }
      } catch (_) {
        // 静默失败，TLDR是锦上添花
      }
    }
  }

  private getRecommendations(): void {
    if (this.papers.length === 0) return;
    try {
      const scored: ScoredPaper[] = [];
      for (const p of this.papers) {
        const s: ScoredPaper = { paper: p, score: RecommendService.score(p) };
        scored.push(s);
      }
      scored.sort((a: ScoredPaper, b: ScoredPaper) => b.score - a.score);
      this.recommendedPapers = scored.slice(0, 3).map((s: ScoredPaper) => s.paper);
    } catch (_) {
      // 推荐失败不影响主功能
    }
  }

  toggleFavorite(paper: Paper): void {
    if (this.favoriteIds.includes(paper.id)) {
      PreferencesUtil.removeFavorite(paper.id);
      this.favoriteIds = this.favoriteIds.filter(id => id !== paper.id);
      if (this.currentIndex === FAVORITES_INDEX) {
        this.papers = this.papers.filter(p => p.id !== paper.id);
      }
    } else {
      PreferencesUtil.addFavorite(paper);
      this.favoriteIds = [...this.favoriteIds, paper.id];
    }
  }

  private async loadReadHistory(): Promise<void> {
    const ids = await PreferencesUtil.get('read_paper_ids', '[]') as string;
    try {
      const arr = JSON.parse(ids) as string[];
      this.readPaperIds = arr;
    } catch (_) {
      this.readPaperIds = [];
    }
  }

  private async markAsRead(paperId: string): Promise<void> {
    if (!this.readPaperIds.includes(paperId)) {
      let updated = [...this.readPaperIds, paperId];
      // 最多缓存最近500个已读ID，避免存储膨胀
      if (updated.length > 500) {
        updated = updated.slice(updated.length - 500);
      }
      this.readPaperIds = updated;
      await PreferencesUtil.put('read_paper_ids', JSON.stringify(this.readPaperIds));
    }
  }

  private isPublishedToday(paper: Paper): boolean {
    if (!paper.published) return false;
    const today = new Date();
    const todayStr = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
    return paper.published.startsWith(todayStr);
  }

  openPaperDetail(paper: Paper): void {
    this.markAsRead(paper.id);
    AppStorage.setOrCreate('selectedPaperJson', JSON.stringify(paper));
    router.pushUrl({ url: 'pages/PaperDetail' });
  }

  formatDate(dateStr: string): string {
    if (!dateStr) return '';
    return dateStr.substring(0, 10);
  }

  getAuthorsText(paper: Paper): string {
    return paper.authors.map(a => a.name).join(', ');
  }

  getAffiliationsText(paper: Paper): string {
    const affs: string[] = [];
    for (const a of paper.authors) {
      if (a.affiliation && !affs.includes(a.affiliation)) {
        affs.push(a.affiliation);
      }
    }
    return affs.join(' · ');
  }

  build() {
    Column() {
      // ---- Title Bar ----
      if (this.showSearchBar) {
        Row({ space: 8 }) {
          TextInput({ placeholder: '搜索 arXiv 论文...', text: this.searchKeyword })
            .layoutWeight(1)
            .height(36)
            .fontSize(15)
            .backgroundColor('#F2F2F7')
            .borderRadius(10)
            .padding({ left: 12, right: 12 })
            .onChange((v: string) => { this.searchKeyword = v; })
            .onSubmit(() => { this.doGlobalSearch(); })

          Text('取消')
            .fontSize(15)
            .fontColor('#007AFF')
            .onClick(() => { this.closeSearchMode(); })
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 16 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor('#FFFFFF')
      } else {
        Row() {
          Text('arXplore')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1D1D1F')

          Blank()

          Text('搜索')
            .fontSize(14)
            .fontColor('#007AFF')
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => { this.openSearchMode(); })

          Text('管理分类')
            .fontSize(14)
            .fontColor('#007AFF')
            .padding({ left: 8, right: 4, top: 4, bottom: 4 })
            .onClick(() => {
              router.pushUrl({ url: 'pages/CategoryManage' });
            })
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 16 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor('#FFFFFF')
      }

      // ---- Category Tabs ----
      Scroll() {
        Row({ space: 8 }) {
          Text('收藏')
            .fontSize(13)
            .fontColor(this.currentIndex === FAVORITES_INDEX ? '#FFFFFF' : '#3C3C43')
            .backgroundColor(this.currentIndex === FAVORITES_INDEX ? '#F53F3F' : '#F2F2F7')
            .borderRadius(16)
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .onClick(() => {
              if (this.currentIndex !== FAVORITES_INDEX) {
                this.currentIndex = FAVORITES_INDEX;
                this.loadPapers(false);
              }
            })

          ForEach(this.categories, (cat: Category, idx?: number) => {
            Text(cat.name)
              .fontSize(13)
              .fontColor(this.currentIndex === (idx as number) ? '#FFFFFF' : '#3C3C43')
              .backgroundColor(this.currentIndex === (idx as number) ? '#007AFF' : '#F2F2F7')
              .borderRadius(16)
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .onClick(() => {
                const i = idx as number;
                if (this.currentIndex !== i) {
                  this.currentIndex = i;
                  this.loadPapers(false);
                }
              })
          }, (cat: Category) => cat.id)
        }
        .padding({ left: 16, right: 16 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(44)
      .backgroundColor('#FFFFFF')

      // ---- Content Area ----
      if (this.isLoading && this.papers.length === 0) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color('#007AFF')
          Text('正在加载...')
            .fontSize(14)
            .fontColor('#86868B')
            .margin({ top: 12 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMsg) {
        Column() {
          Text(this.errorMsg)
            .fontSize(14)
            .fontColor('#86868B')
          Text('下拉刷新重试')
            .fontSize(13)
            .fontColor('#007AFF')
            .margin({ top: 8 })
            .onClick(() => {
              this.loadPapers(true);
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.papers.length === 0) {
        if (this.currentIndex === FAVORITES_INDEX) {
          // 收藏列表为空
          Column() {
            Text('⭐')
              .fontSize(64)
            Text('还没有收藏的论文')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor('#1D1D1F')
              .margin({ top: 16 })
            Text('在速览中右滑收藏感兴趣的论文')
              .fontSize(14)
              .fontColor('#86868B')
              .margin({ top: 8 })
            Button('开始速览')
              .fontSize(15)
              .fontColor('#007AFF')
              .backgroundColor('#F2F2F7')
              .borderRadius(20)
              .padding({ left: 24, right: 24, top: 10, bottom: 10 })
              .margin({ top: 20 })
              .onClick(() => {
                if (this.onSwitchTab) {
                  this.onSwitchTab(1); // 切换到速览 Tab
                }
              })
          }
          .width('100%')
          .padding({ top: 120 })
          .alignItems(HorizontalAlign.Center)
          .layoutWeight(1)
        } else if (this.currentIndex === SEARCH_INDEX) {
          // 搜索无结果
          Column() {
            Text('未找到相关论文')
              .fontSize(14)
              .fontColor('#86868B')
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          // 首页论文列表为空
          Column() {
            Text('🔭')
              .fontSize(64)
            Text('暂无论文')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor('#1D1D1F')
              .margin({ top: 16 })
            Text('选择感兴趣的分类\n开始探索学术前沿')
              .fontSize(14)
              .fontColor('#86868B')
              .textAlign(TextAlign.Center)
              .margin({ top: 8 })
          }
          .width('100%')
          .padding({ top: 120 })
          .alignItems(HorizontalAlign.Center)
          .layoutWeight(1)
        }
      } else {
        Refresh({ refreshing: $$this.isRefreshing }) {
          List({ space: 10 }) {
            // Search result count
            if (this.currentIndex === SEARCH_INDEX && this.searchResultCount > 0) {
              ListItem() {
                Text(`找到 ${this.searchResultCount}${this.hasMore ? '+' : ''} 篇相关论文`)
                  .fontSize(12)
                  .fontColor('#86868B')
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 6, bottom: 0 })
              }
            }

            // Cache hint at top
            if (this.cacheHint) {
              ListItem() {
                Text(this.cacheHint)
                  .fontSize(11)
                  .fontColor('#C7C7CC')
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 4, bottom: 0 })
              }
            }

            // 今日推荐（仅在论文分类tab显示，不在收藏和搜索中显示）
            if (this.recommendedPapers.length > 0 && this.currentIndex >= 0 && this.currentIndex !== SEARCH_INDEX) {
              ListItem() {
                this.DailyRecommendation()
              }
            }

            ForEach(this.papers, (paper: Paper) => {
              ListItem() {
                if (this.currentIndex === FAVORITES_INDEX) {
                  this.FavoriteCard(paper)
                } else {
                  this.PaperCard(paper)
                }
              }
              .padding({ left: 16, right: 16 })
            }, (paper: Paper) => paper.id)

            if (this.hasMore) {
              ListItem() {
                Row() {
                  LoadingProgress().width(24).height(24).color('#C7C7CC')
                  Text('加载更多...').fontSize(13).fontColor('#C7C7CC').margin({ left: 8 })
                }
                .width('100%')
                .height(48)
                .justifyContent(FlexAlign.Center)
              }
            }
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ top: 4, bottom: 16 })
          .divider({ strokeWidth: 0 })
          .onReachEnd(() => {
            if (this.currentIndex === SEARCH_INDEX) {
              this.loadMoreSearchResults();
            } else {
              this.loadMorePapers();
            }
          })
        }
        .onRefreshing(() => {
          if (this.currentIndex === SEARCH_INDEX) {
            this.doGlobalSearch();
            this.isRefreshing = false;
          } else {
            this.loadPapers(true);
          }
        })
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F2F7')
  }

  @Builder
  DailyRecommendation() {
    Column() {
      // 标题行
      Row() {
        Text('✨')
          .fontSize(18)
        Text('今日推荐')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1D1D1F')
          .margin({ left: 6 })
        Blank()
        Text('基于你的偏好')
          .fontSize(12)
          .fontColor('#86868B')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 12 })

      // 横滑卡片
      Scroll() {
        Row({ space: 12 }) {
          ForEach(this.recommendedPapers, (paper: Paper) => {
            Column() {
              // 分类标签
              Text(paper.categories[0] || '')
                .fontSize(11)
                .fontColor('#007AFF')
                .backgroundColor('#F0F7FF')
                .borderRadius(6)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })

              // 标题
              Text(paper.title)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1D1D1F')
                .maxLines(3)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 10 })

              // TLDR（如果有）
              if (paper.tldr) {
                Text(paper.tldr)
                  .fontSize(12)
                  .fontColor('#007AFF')
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 8 })
              }

              Blank()

              // 作者
              Text(paper.authors.slice(0, 2).map((a: Author) => a.name).join(', '))
                .fontSize(11)
                .fontColor('#86868B')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width(240)
            .height(180)
            .padding(16)
            .backgroundColor('#FFFFFF')
            .borderRadius(16)
            .shadow({ radius: 12, color: '#0A000000', offsetX: 0, offsetY: 2 })
            .onClick(() => {
              this.openPaperDetail(paper);
            })
          }, (paper: Paper) => paper.id + '_rec')
        }
        .padding({ left: 20, right: 20 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .margin({ bottom: 8 })
  }

  @Builder
  PaperCard(paper: Paper) {
    Column({ space: 8 }) {
      Row() {
        Text(paper.title)
          .fontSize(15)
          .fontWeight(this.readPaperIds.includes(paper.id) ? FontWeight.Normal : FontWeight.Medium)
          .fontColor(this.readPaperIds.includes(paper.id) ? '#86868B' : '#1D1D1F')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        SymbolGlyph(this.favoriteIds.includes(paper.id) ? $r('sys.symbol.star_fill') : $r('sys.symbol.ohos_star'))
          .fontSize(22)
          .fontColor([this.favoriteIds.includes(paper.id) ? '#FF9500' : '#C7C7CC'])
          .margin({ left: 8 })
          .onClick(() => {
            this.toggleFavorite(paper);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (paper.authors.length > 0) {
        Text(this.getAuthorsText(paper))
          .fontSize(12)
          .fontColor('#3C3C43')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      if (this.getAffiliationsText(paper)) {
        Text(this.getAffiliationsText(paper))
          .fontSize(11)
          .fontColor('#86868B')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      if (paper.tldr && paper.tldr.length > 0) {
        Text(paper.tldr)
          .fontSize(13)
          .fontColor('#007AFF')
          .fontWeight(FontWeight.Medium)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 8 })
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor('#F0F7FF')
          .borderRadius(8)
          .width('100%')
      }

      Text(paper.summary)
        .fontSize(13)
        .fontColor('#3C3C43')
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(20)
        .width('100%')

      Row() {
        Text(this.formatDate(paper.published))
          .fontSize(11)
          .fontColor('#86868B')

        Blank()

        Row({ space: 4 }) {
          if (this.isPublishedToday(paper)) {
            Text('NEW')
              .fontSize(10)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .backgroundColor('#007AFF')
              .borderRadius(4)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          }

          ForEach(paper.categories.slice(0, 3), (cat: string) => {
            Text(cat)
              .fontSize(10)
              .fontColor('#007AFF')
              .backgroundColor('#EDF4FF')
              .borderRadius(10)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          }, (cat: string) => cat)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .border({ width: 1, color: '#E5E5EA', style: BorderStyle.Solid })
    .shadow({ radius: 4, color: '#0D000000', offsetX: 0, offsetY: 2 })
    .opacity(this.readPaperIds.includes(paper.id) ? 0.7 : 1.0)
    .onClick(() => { this.openPaperDetail(paper); })
  }

  @Builder
  FavoriteCard(paper: Paper) {
    Column({ space: 8 }) {
      Row() {
        Text(paper.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1D1D1F')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.star_fill'))
          .fontSize(22)
          .fontColor(['#FF9500'])
          .margin({ left: 8 })
          .onClick(() => { this.toggleFavorite(paper); })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (paper.authors.length > 0) {
        Text(this.getAuthorsText(paper))
          .fontSize(12)
          .fontColor('#3C3C43')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      Text(paper.summary)
        .fontSize(13)
        .fontColor('#3C3C43')
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(20)
        .width('100%')

      Row() {
        Text(this.formatDate(paper.published))
          .fontSize(11)
          .fontColor('#86868B')

        Blank()

        Row({ space: 4 }) {
          ForEach(paper.categories.slice(0, 3), (cat: string) => {
            Text(cat)
              .fontSize(10)
              .fontColor('#F53F3F')
              .backgroundColor('#FFF1F0')
              .borderRadius(10)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          }, (cat: string) => cat)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .border({ width: 1, color: '#FFE8E6', style: BorderStyle.Solid })
    .shadow({ radius: 4, color: '#0D000000', offsetX: 0, offsetY: 2 })
    .onClick(() => { this.openPaperDetail(paper); })
  }
}
