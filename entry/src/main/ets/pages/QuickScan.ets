import { router } from '@kit.ArkUI';
import { Paper, Category } from '../model/DataModels';
import { ArxivService } from '../service/ArxivService';
import { PreferencesUtil } from '../common/PreferencesUtil';

@Entry
@Component
struct QuickScan {
  @State papers: Paper[] = [];
  @State currentIdx: number = 0;
  @State isLoading: boolean = true;
  @State loadingCategory: string = '';
  @State errorMsg: string = '';
  @State favoriteIds: string[] = [];
  @State cardOffsetX: number = 0;
  @State cardOpacity: number = 1;
  @State cardRotate: number = 0;
  @State savedCount: number = 0;
  @State skippedCount: number = 0;
  private animating: boolean = false;

  aboutToAppear(): void {
    this.loadPapers();
  }

  async loadPapers(): Promise<void> {
    await PreferencesUtil.init(getContext(this));
    this.favoriteIds = PreferencesUtil.getFavoriteIds();
    const categories = await PreferencesUtil.getCategories();

    const all: Paper[] = [];
    const ids = new Set<string>();
    const favSet = new Set<string>(this.favoriteIds);
    const limit = Math.min(4, categories.length);

    for (let i = 0; i < limit; i++) {
      this.loadingCategory = categories[i].name;
      try {
        const results = await ArxivService.searchPapers(categories[i].query, 0, 12, false);
        for (const p of results) {
          if (!ids.has(p.id) && !favSet.has(p.id)) {
            ids.add(p.id);
            all.push(p);
          }
        }
      } catch (_) {}
    }

    for (let i = all.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      const tmp = all[i];
      all[i] = all[j];
      all[j] = tmp;
    }

    this.papers = all.slice(0, 30);
    this.isLoading = false;
    if (this.papers.length === 0) {
      this.errorMsg = '没有新论文可速览';
    }
  }

  isDone(): boolean {
    return !this.isLoading && this.currentIdx >= this.papers.length && this.papers.length > 0;
  }

  swipeIndicator(): number {
    // Returns -1 for skip, +1 for save, 0 for neutral
    if (Math.abs(this.cardOffsetX) < 40) return 0;
    return this.cardOffsetX > 0 ? 1 : -1;
  }

  skip(): void {
    if (this.animating || this.currentIdx >= this.papers.length) return;
    this.animating = true;
    this.skippedCount++;
    animateTo({ duration: 250, curve: Curve.EaseOut }, () => {
      this.cardOffsetX = -600;
      this.cardOpacity = 0;
      this.cardRotate = -15;
    });
    setTimeout(() => {
      this.currentIdx++;
      this.cardOffsetX = 0;
      this.cardOpacity = 1;
      this.cardRotate = 0;
      this.animating = false;
    }, 270);
  }

  save(): void {
    if (this.animating || this.currentIdx >= this.papers.length) return;
    this.animating = true;
    const paper = this.papers[this.currentIdx];
    if (paper) {
      PreferencesUtil.addFavorite(paper);
      this.favoriteIds = [...this.favoriteIds, paper.id];
      this.savedCount++;
    }
    animateTo({ duration: 250, curve: Curve.EaseOut }, () => {
      this.cardOffsetX = 600;
      this.cardOpacity = 0;
      this.cardRotate = 15;
    });
    setTimeout(() => {
      this.currentIdx++;
      this.cardOffsetX = 0;
      this.cardOpacity = 1;
      this.cardRotate = 0;
      this.animating = false;
    }, 270);
  }

  openDetail(): void {
    if (this.currentIdx >= this.papers.length) return;
    AppStorage.setOrCreate('selectedPaperJson', JSON.stringify(this.papers[this.currentIdx]));
    router.pushUrl({ url: 'pages/PaperDetail' });
  }

  fmtDate(d: string): string { return d ? d.substring(0, 10) : ''; }

  readTime(paper: Paper): number {
    return Math.max(1, Math.ceil(paper.summary.split(' ').length / 40));
  }

  pageTransition() {
    PageTransitionEnter({ duration: 250 }).slide(SlideEffect.Right)
    PageTransitionExit({ duration: 200 }).opacity(0.8)
  }

  build() {
    Column() {
      // Header
      Row() {
        Row() {
          Text('\u2039').fontSize(34).fontColor('#007AFF').height(44).textAlign(TextAlign.Center)
        }
        .width(56).height(44).justifyContent(FlexAlign.Center)
        .onClick(() => { router.back(); })

        Text('速览')
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#1D2129')

        Blank()

        if (!this.isDone() && this.papers.length > 0 && !this.isLoading) {
          Text(`${this.currentIdx + 1} / ${this.papers.length}`)
            .fontSize(13).fontColor('#AEAEB2').padding({ right: 16 })
        }
      }
      .width('100%').height(44)
      .alignItems(VerticalAlign.Center)
      .backgroundColor('#FFFFFF')

      // Progress bar
      if (this.papers.length > 0 && !this.isDone()) {
        Stack({ alignContent: Alignment.Start }) {
          Row().width('100%').height(3).backgroundColor('#F2F2F7')
          Row()
            .width(`${Math.round(this.currentIdx / this.papers.length * 100)}%`)
            .height(3)
            .backgroundColor('#007AFF')
            .borderRadius(1.5)
        }
        .width('100%').height(3)
      }

      if (this.isLoading) {
        Column({ space: 12 }) {
          LoadingProgress().width(48).height(48).color('#007AFF')
          Text('正在发现论文...').fontSize(15).fontColor('#86909C')
          if (this.loadingCategory) {
            Text(this.loadingCategory).fontSize(13).fontColor('#AEAEB2')
          }
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.errorMsg) {
        Column({ space: 16 }) {
          Text(this.errorMsg).fontSize(15).fontColor('#86909C')
          Text('返回').fontSize(16).fontColor('#007AFF')
            .onClick(() => { router.back(); })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.isDone()) {
        this.CompletionView()
      } else {
        this.CardView()
      }
    }
    .width('100%').height('100%')
    .backgroundColor('#F5F5FA')
  }

  @Builder
  CompletionView() {
    Column({ space: 0 }) {
      Blank()

      Column({ space: 8 }) {
        Text('\u2713')
          .fontSize(48).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
          .width(80).height(80).textAlign(TextAlign.Center)
          .borderRadius(40)
          .backgroundColor('#34C759')

        Text('速览完成')
          .fontSize(24).fontWeight(FontWeight.Bold).fontColor('#1D2129')
          .margin({ top: 16 })

        Text('你已浏览了所有推荐论文')
          .fontSize(14).fontColor('#86909C')
      }
      .alignItems(HorizontalAlign.Center)

      Row({ space: 40 }) {
        Column({ space: 6 }) {
          Text(this.savedCount.toString())
            .fontSize(36).fontWeight(FontWeight.Bold).fontColor('#007AFF')
          Text('已收藏').fontSize(13).fontColor('#86909C')
        }.alignItems(HorizontalAlign.Center)

        Column().width(1).height(40).backgroundColor('#E5E5EA')

        Column({ space: 6 }) {
          Text(this.skippedCount.toString())
            .fontSize(36).fontWeight(FontWeight.Bold).fontColor('#AEAEB2')
          Text('已跳过').fontSize(13).fontColor('#86909C')
        }.alignItems(HorizontalAlign.Center)
      }
      .margin({ top: 32 })

      Blank()

      Button('查看收藏')
        .type(ButtonType.Normal)
        .fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF').backgroundColor('#007AFF')
        .borderRadius(24).width('80%').height(50)
        .onClick(() => { router.back(); })

      Text('返回首页')
        .fontSize(15).fontColor('#86909C').margin({ top: 12, bottom: 48 })
        .onClick(() => { router.back(); })
    }
    .width('100%').layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  CardView() {
    Stack() {
      Column() {
        // Card area with padding
        Column() {
          Blank()

          Stack() {
            // The card
            Column({ space: 0 }) {
              // Top accent bar
              Row()
                .width('100%').height(4)
                .borderRadius({ topLeft: 16, topRight: 16 })
                .backgroundColor(this.swipeIndicator() > 0 ? '#34C759' :
                  this.swipeIndicator() < 0 ? '#FF3B30' : '#007AFF')

              Column({ space: 12 }) {
                // Title
                Text(this.papers[this.currentIdx].title)
                  .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1D1D1F')
                  .lineHeight(26).width('100%')
                  .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })

                // Authors
                Text(this.papers[this.currentIdx].authors.slice(0, 4).map(a => a.name).join(', '))
                  .fontSize(13).fontColor('#86868B')
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')

                // Meta row: categories + date
                Row() {
                  Row({ space: 6 }) {
                    ForEach(this.papers[this.currentIdx].categories.slice(0, 2), (cat: string) => {
                      Text(cat)
                        .fontSize(10).fontColor('#007AFF')
                        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                        .borderRadius(10)
                        .backgroundColor('#EDF4FF')
                    }, (cat: string) => cat)
                  }
                  Blank()
                  Text(`${this.fmtDate(this.papers[this.currentIdx].published)}`)
                    .fontSize(11).fontColor('#AEAEB2')
                }
                .width('100%')

                // Divider
                Row().width('100%').height(1).backgroundColor('#F2F2F7')

                // Abstract
                Text(this.papers[this.currentIdx].summary)
                  .fontSize(14).fontColor('#4E5969')
                  .lineHeight(22).maxLines(6)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')

                // Detail link
                Row() {
                  Text('查看详情')
                    .fontSize(13).fontColor('#007AFF').fontWeight(FontWeight.Medium)
                  Text(' \u203A')
                    .fontSize(15).fontColor('#007AFF')
                }
                .onClick(() => { this.openDetail(); })
              }
              .width('100%')
              .padding({ left: 20, right: 20, top: 16, bottom: 20 })
            }
            .width('100%')
            .backgroundColor('#FFFFFF')
            .borderRadius(16)
            .shadow({ radius: 20, color: '#1A000000', offsetX: 0, offsetY: 8 })
            .translate({ x: this.cardOffsetX })
            .opacity(this.cardOpacity)
            .rotate({ angle: this.cardRotate })
            .gesture(
              PanGesture({ direction: PanDirection.Horizontal, distance: 15 })
                .onActionUpdate((event?: GestureEvent) => {
                  if (event && !this.animating) {
                    this.cardOffsetX = event.offsetX;
                    this.cardRotate = event.offsetX * 0.03;
                    this.cardOpacity = Math.max(0.5, 1 - Math.abs(event.offsetX) / 500);
                  }
                })
                .onActionEnd((event?: GestureEvent) => {
                  if (!event || this.animating) return;
                  if (event.offsetX > 100) {
                    this.save();
                  } else if (event.offsetX < -100) {
                    this.skip();
                  } else {
                    animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
                      this.cardOffsetX = 0;
                      this.cardOpacity = 1;
                      this.cardRotate = 0;
                    });
                  }
                })
            )

            // Swipe indicator overlays
            if (this.swipeIndicator() > 0) {
              Row() {
                Text('收藏')
                  .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#34C759')
                  .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                  .borderRadius(8)
                  .border({ width: 3, color: '#34C759', style: BorderStyle.Solid })
                  .rotate({ angle: -20 })
              }
              .width('100%').height('100%')
              .justifyContent(FlexAlign.Start)
              .alignItems(VerticalAlign.Top)
              .padding({ left: 30, top: 30 })
              .hitTestBehavior(HitTestMode.None)
            }

            if (this.swipeIndicator() < 0) {
              Row() {
                Blank()
                Text('跳过')
                  .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FF3B30')
                  .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                  .borderRadius(8)
                  .border({ width: 3, color: '#FF3B30', style: BorderStyle.Solid })
                  .rotate({ angle: 20 })
              }
              .width('100%').height('100%')
              .alignItems(VerticalAlign.Top)
              .padding({ right: 30, top: 30 })
              .hitTestBehavior(HitTestMode.None)
            }
          }
          .width('100%')

          Blank()
        }
        .width('100%').layoutWeight(1)
        .padding({ left: 20, right: 20 })

        // Action buttons
        Row() {
          // Skip button
          Column() {
            Text('\u2717').fontSize(28).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
          }
          .width(64).height(64).borderRadius(32)
          .backgroundColor('#FF3B30')
          .justifyContent(FlexAlign.Center)
          .shadow({ radius: 8, color: '#33FF3B30', offsetX: 0, offsetY: 4 })
          .onClick(() => { this.skip(); })

          // Detail button (small, in the middle)
          Column() {
            Text('\u2197').fontSize(18).fontColor('#86909C')
          }
          .width(44).height(44).borderRadius(22)
          .backgroundColor('#FFFFFF')
          .justifyContent(FlexAlign.Center)
          .border({ width: 1, color: '#E5E5EA', style: BorderStyle.Solid })
          .onClick(() => { this.openDetail(); })

          // Save button
          Column() {
            Text('\u2605').fontSize(28).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
          }
          .width(64).height(64).borderRadius(32)
          .backgroundColor('#007AFF')
          .justifyContent(FlexAlign.Center)
          .shadow({ radius: 8, color: '#33007AFF', offsetX: 0, offsetY: 4 })
          .onClick(() => { this.save(); })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceEvenly)
        .alignItems(VerticalAlign.Center)
        .padding({ bottom: 8 })

        // Stats
        Row({ space: 16 }) {
          Row({ space: 4 }) {
            Text('\u2605').fontSize(12).fontColor('#007AFF')
            Text(`${this.savedCount}`).fontSize(12).fontColor('#007AFF').fontWeight(FontWeight.Medium)
          }
          Text('\u00B7').fontSize(14).fontColor('#D1D1D6')
          Row({ space: 4 }) {
            Text('\u2717').fontSize(12).fontColor('#AEAEB2')
            Text(`${this.skippedCount}`).fontSize(12).fontColor('#AEAEB2').fontWeight(FontWeight.Medium)
          }
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .padding({ bottom: 36 })
      }
      .width('100%').height('100%')
    }
    .width('100%').layoutWeight(1)
  }
}
