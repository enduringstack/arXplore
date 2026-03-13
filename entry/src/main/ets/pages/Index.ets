import { router } from '@kit.ArkUI';
import { Paper, Category } from '../model/DataModels';
import { ArxivService } from '../service/ArxivService';
import { PreferencesUtil } from '../common/PreferencesUtil';

const FAVORITES_INDEX = -1;
const SEARCH_INDEX = -2;

@Entry
@Component
struct Index {
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
      this.hasMore = false;
      this.isLoading = false;
      this.isRefreshing = false;
      return;
    }

    if (this.currentIndex < 0 || this.currentIndex >= this.categories.length) {
      this.papers = [];
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
    } catch (_e) {
      if (reqId !== this.loadRequestId) return;
      this.errorMsg = '网络请求失败，请下拉刷新重试';
      this.papers = [];
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

  openPaperDetail(paper: Paper): void {
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
            .backgroundColor('#F2F3F5')
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
            .fontColor('#1D2129')

          Blank()

          Text('速览')
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor('#007AFF')
            .borderRadius(14)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .onClick(() => { router.pushUrl({ url: 'pages/QuickScan' }); })

          Text('计划')
            .fontSize(14)
            .fontColor('#007AFF')
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => { router.pushUrl({ url: 'pages/ReadingPlan' }); })

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
            .fontColor(this.currentIndex === FAVORITES_INDEX ? '#FFFFFF' : '#4E5969')
            .backgroundColor(this.currentIndex === FAVORITES_INDEX ? '#F53F3F' : '#F2F3F5')
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
              .fontColor(this.currentIndex === (idx as number) ? '#FFFFFF' : '#4E5969')
              .backgroundColor(this.currentIndex === (idx as number) ? '#007AFF' : '#F2F3F5')
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
            .fontColor('#86909C')
            .margin({ top: 12 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMsg) {
        Column() {
          Text(this.errorMsg)
            .fontSize(14)
            .fontColor('#86909C')
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
        Column() {
          Text(this.currentIndex === FAVORITES_INDEX ? '还没有收藏的论文' :
               this.currentIndex === SEARCH_INDEX ? '未找到相关论文' : '暂无论文')
            .fontSize(14)
            .fontColor('#86909C')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Refresh({ refreshing: $$this.isRefreshing }) {
          List({ space: 10 }) {
            // Search result count
            if (this.currentIndex === SEARCH_INDEX && this.searchResultCount > 0) {
              ListItem() {
                Text(`找到 ${this.searchResultCount}${this.hasMore ? '+' : ''} 篇相关论文`)
                  .fontSize(12)
                  .fontColor('#86909C')
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
                  .fontColor('#C9CDD4')
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 4, bottom: 0 })
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
                  LoadingProgress().width(24).height(24).color('#C9CDD4')
                  Text('加载更多...').fontSize(13).fontColor('#C9CDD4').margin({ left: 8 })
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
  PaperCard(paper: Paper) {
    Column({ space: 8 }) {
      Row() {
        Text(paper.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1D2129')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text(this.favoriteIds.includes(paper.id) ? '★' : '☆')
          .fontSize(22)
          .fontColor(this.favoriteIds.includes(paper.id) ? '#F53F3F' : '#C9CDD4')
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
          .fontColor('#4E5969')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      if (this.getAffiliationsText(paper)) {
        Text(this.getAffiliationsText(paper))
          .fontSize(11)
          .fontColor('#86909C')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      Text(paper.summary)
        .fontSize(13)
        .fontColor('#4E5969')
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(20)
        .width('100%')

      Row() {
        Text(this.formatDate(paper.published))
          .fontSize(11)
          .fontColor('#86909C')

        Blank()

        Row({ space: 4 }) {
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
    .border({ width: 1, color: '#E8EDF3', style: BorderStyle.Solid })
    .shadow({ radius: 4, color: '#0D000000', offsetX: 0, offsetY: 2 })
    .onClick(() => { this.openPaperDetail(paper); })
  }

  @Builder
  FavoriteCard(paper: Paper) {
    Column({ space: 8 }) {
      Row() {
        Text(paper.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1D2129')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text('★')
          .fontSize(22)
          .fontColor('#F53F3F')
          .margin({ left: 8 })
          .onClick(() => { this.toggleFavorite(paper); })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (paper.authors.length > 0) {
        Text(this.getAuthorsText(paper))
          .fontSize(12)
          .fontColor('#4E5969')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      Text(paper.summary)
        .fontSize(13)
        .fontColor('#4E5969')
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(20)
        .width('100%')

      Row() {
        Text(this.formatDate(paper.published))
          .fontSize(11)
          .fontColor('#86909C')

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
