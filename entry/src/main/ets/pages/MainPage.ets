import { IndexPage } from './Index';
import { QuickScanPage } from './QuickScan';
import { ReadingPlanPage } from './ReadingPlan';

@Entry
@Component
struct MainPage {
  @State currentIndex: number = 0;
  private controller: TabsController = new TabsController();

  @Builder
  TabBarItem(title: string, iconNormal: Resource, iconSelected: Resource, index: number) {
    Column() {
      SymbolGlyph(index === this.currentIndex ? iconSelected : iconNormal)
        .fontSize(24)
        .fontColor([index === this.currentIndex ? '#007AFF' : '#8E8E93'])
      Text(title)
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor(index === this.currentIndex ? '#007AFF' : '#8E8E93')
        .margin({ top: 2 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Tabs({ barPosition: BarPosition.End, controller: this.controller }) {
      TabContent() {
        IndexPage({ onSwitchTab: (index: number) => {
          this.currentIndex = index;
          this.controller.changeIndex(index);
        }})
      }
      .tabBar(this.TabBarItem('发现', $r('sys.symbol.discover'), $r('sys.symbol.discover_fill'), 0))

      TabContent() {
        QuickScanPage({ onSwitchTab: (index: number) => {
          this.currentIndex = index;
          this.controller.changeIndex(index);
        }})
      }
      .tabBar(this.TabBarItem('速览', $r('sys.symbol.rectangle_stack'), $r('sys.symbol.rectangle_stack'), 1))

      TabContent() {
        ReadingPlanPage()
      }
      .tabBar(this.TabBarItem('收藏', $r('sys.symbol.star_fill'), $r('sys.symbol.star_fill'), 2))
    }
    .scrollable(false)
    .barMode(BarMode.Fixed)
    .barHeight(56)
    .animationDuration(0)
    .onChange((index: number) => {
      this.currentIndex = index;
    })
  }
}
