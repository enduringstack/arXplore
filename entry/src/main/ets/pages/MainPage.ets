import { IndexPage } from './Index';
import { QuickScanPage } from './QuickScan';
import { ReadingPlanPage } from './ReadingPlan';

@Entry
@Component
struct MainPage {
  @State currentIndex: number = 0;
  private controller: TabsController = new TabsController();

  @Builder
  TabBarItem(title: string, iconNormal: string, iconSelected: string, index: number) {
    Column() {
      Text(index === this.currentIndex ? iconSelected : iconNormal)
        .fontSize(24)
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
      .tabBar(this.TabBarItem('探索', '\uD83E\uDDED', '\uD83E\uDDED', 0))

      TabContent() {
        QuickScanPage({ onSwitchTab: (index: number) => {
          this.currentIndex = index;
          this.controller.changeIndex(index);
        }})
      }
      .tabBar(this.TabBarItem('速览', '\u26A1', '\u26A1', 1))

      TabContent() {
        ReadingPlanPage()
      }
      .tabBar(this.TabBarItem('书架', '\uD83D\uDCDA', '\uD83D\uDCDA', 2))
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
