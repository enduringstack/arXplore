import { router } from '@kit.ArkUI';
import { Category, getDefaultCategories } from '../model/DataModels';
import { PreferencesUtil } from '../common/PreferencesUtil';

@Entry
@Component
struct CategoryManage {
  @State categories: Category[] = [];
  @State newName: string = '';
  @State newQuery: string = '';
  @State showHint: boolean = false;

  aboutToAppear(): void {
    this.loadCategories();
  }

  async loadCategories(): Promise<void> {
    await PreferencesUtil.init(getContext(this));
    this.categories = await PreferencesUtil.getCategories();
  }

  async addCategory(): Promise<void> {
    const name = this.newName.trim();
    const query = this.newQuery.trim();
    if (!name || !query) return;

    const id = 'custom_' + Date.now().toString();
    const newCat: Category = { id, name, query, isDefault: false };
    this.categories = [...this.categories, newCat];
    await PreferencesUtil.saveCategories(this.categories);
    this.newName = '';
    this.newQuery = '';
  }

  async removeCategory(idx: number): Promise<void> {
    this.categories = this.categories.filter((_c: Category, i: number) => i !== idx);
    await PreferencesUtil.saveCategories(this.categories);
  }

  async resetDefaults(): Promise<void> {
    this.categories = getDefaultCategories();
    await PreferencesUtil.saveCategories(this.categories);
  }

  pageTransition() {
    PageTransitionEnter({ duration: 250 }).slide(SlideEffect.Right)
    PageTransitionExit({ duration: 200 }).opacity(0.8)
  }

  build() {
    Column() {
      // ---- Top Bar ----
      Row() {
        Row() {
          Text('\u2039').fontSize(34).fontColor('#007AFF').height(44).textAlign(TextAlign.Center)
        }
        .width(56).height(44).justifyContent(FlexAlign.Center)
        .onClick(() => { router.back(); })

        Text('分类管理')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1D1D1F')

        Blank()

        Text('恢复默认')
          .fontSize(14)
          .fontColor('#F53F3F')
          .onClick(() => {
            this.resetDefaults();
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor('#FFFFFF')

      // ---- Category List ----
      List({ space: 1 }) {
        ForEach(this.categories, (cat: Category, idx?: number) => {
          ListItem() {
            Row() {
              Column({ space: 4 }) {
                Text(cat.name)
                  .fontSize(15)
                  .fontColor('#1D1D1F')
                  .fontWeight(FontWeight.Medium)

                Text(cat.query)
                  .fontSize(12)
                  .fontColor('#86868B')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Text('删除')
                .fontSize(13)
                .fontColor('#F53F3F')
                .padding({ left: 12, right: 4, top: 4, bottom: 4 })
                .onClick(() => {
                  this.removeCategory(idx as number);
                })
            }
            .width('100%')
            .padding(14)
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
          }
        }, (cat: Category) => cat.id)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ top: 12, left: 16, right: 16 })
      .divider({ strokeWidth: 0 })

      // ---- Add Category Section ----
      Column({ space: 10 }) {
        Text('添加新分类')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1D1D1F')
          .width('100%')

        TextInput({ placeholder: '分类名称 (如: 具身智能VLA)', text: $$this.newName })
          .fontSize(14)
          .height(44)
          .backgroundColor('#F2F2F7')
          .borderRadius(8)
          .width('100%')

        Row({ space: 8 }) {
          TextInput({ placeholder: 'arXiv搜索语句', text: $$this.newQuery })
            .fontSize(14)
            .height(44)
            .backgroundColor('#F2F2F7')
            .borderRadius(8)
            .layoutWeight(1)

          Text('?')
            .fontSize(16)
            .fontColor('#007AFF')
            .width(32)
            .height(32)
            .textAlign(TextAlign.Center)
            .borderRadius(16)
            .backgroundColor('#E8F3FF')
            .onClick(() => {
              this.showHint = !this.showHint;
            })
        }

        if (this.showHint) {
          Column({ space: 4 }) {
            Text('arXiv搜索语法示例:')
              .fontSize(13)
              .fontColor('#3C3C43')
              .fontWeight(FontWeight.Medium)
            Text('• all:"keyword" - 搜索所有字段')
              .fontSize(12)
              .fontColor('#86868B')
            Text('• ti:"keyword" - 搜索标题')
              .fontSize(12)
              .fontColor('#86868B')
            Text('• au:"name" - 搜索作者')
              .fontSize(12)
              .fontColor('#86868B')
            Text('• cat:cs.AI - 搜索分类')
              .fontSize(12)
              .fontColor('#86868B')
            Text('• 用 AND / OR 连接多个条件')
              .fontSize(12)
              .fontColor('#86868B')
            Text('例: all:"gaussian splatting"')
              .fontSize(12)
              .fontColor('#007AFF')
          }
          .width('100%')
          .padding(10)
          .backgroundColor('#F2F2F7')
          .borderRadius(8)
          .alignItems(HorizontalAlign.Start)
        }

        Button('添加分类')
          .type(ButtonType.Normal)
          .fontSize(15)
          .fontColor('#FFFFFF')
          .backgroundColor(this.newName.trim() && this.newQuery.trim() ? '#007AFF' : '#C7C7CC')
          .borderRadius(8)
          .width('100%')
          .height(44)
          .onClick(() => {
            this.addCategory();
          })
      }
      .width('100%')
      .padding(16)
      .backgroundColor('#FFFFFF')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F2F7')
  }
}
