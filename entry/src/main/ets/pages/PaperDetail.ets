import { router, componentSnapshot } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { http } from '@kit.NetworkKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { PdfView, pdfViewManager, pdfService } from '@kit.PDFKit';
import { localChatModel } from '@kit.DataAugmentationKit';
import { image } from '@kit.ImageKit';
import { Paper, Author } from '../model/DataModels';
import { PreferencesUtil } from '../common/PreferencesUtil';
import { ArxivService } from '../service/ArxivService';
import { CloudLLMService } from '../service/CloudLLMService';

const SCROLL_TRACK_JS: string =
  "if(!window._rp_binds){window._rp_binds=1;" +
  "window._rp_sel='';" +
  "document.addEventListener('selectionchange',function(){" +
  "var s=window.getSelection();" +
  "if(s&&s.toString().trim().length>0){window._rp_sel=s.toString().trim();}" +
  "});" +
  "function _rpTrack(){" +
  "var st=document.documentElement.scrollTop||document.body.scrollTop;" +
  "var sh=document.documentElement.scrollHeight-window.innerHeight;" +
  "var p=sh>0?Math.round(st/sh*100):0;" +
  "console.info('_RP_:'+p);}" +
  "window.addEventListener('scroll',_rpTrack);" +
  "setTimeout(_rpTrack,500);}";

const MODE_ABSTRACT = 0;
const MODE_PDF = 1;
const MODE_HTML = 2;

const ANNO_COLORS: number[] = [
  0x60FFCC02, 0x6034C759, 0x60FF3B30, 0x60007AFF, 0x60FF9500,
];
const ANNO_UI_COLORS: string[] = [
  '#FFCC02', '#34C759', '#FF3B30', '#007AFF', '#FF9500',
];

@Entry
@Component
struct PaperDetail {
  @State paper: Paper | null = null;
  @State readingProgress: number = 0;
  @State viewMode: number = MODE_ABSTRACT;
  @State isFavorite: boolean = false;

  @State pdfLoading: boolean = false;
  @State pdfError: string = '';
  private pdfController: pdfViewManager.PdfController = new pdfViewManager.PdfController();
  @State pageCount: number = 0;
  @State currentPage: number = 1;
  @State fitWidth: boolean = true;
  @State layoutSingle: boolean = true;

  @State showSearch: boolean = false;
  @State searchText: string = '';
  @State matchCount: number = 0;
  @State matchIndex: number = 0;

  @State showJump: boolean = false;
  @State jumpText: string = '';

  @State activeTool: number = -1;
  @State colorIdx: number = 0;
  @State showColors: boolean = false;
  @State unsaved: boolean = false;

  @State webUrl: string = '';
  @State webProgress: number = 0;
  @State webScroll: number = 0;
  private webCtrl: webview.WebviewController = new webview.WebviewController();
  private scroller: Scroller = new Scroller();

  @State pdfDownloadProgress: number = 0; // 0-100

  @State llmInited: boolean = false;
  @State summaryText: string = '';
  @State summaryLoading: boolean = false;
  @State showSummary: boolean = false;
  @State toastMsg: string = '';
  @State selectedText: string = '';
  @State relatedPapers: Paper[] = [];
  @State relatedLoading: boolean = false;
  @State showShareCard: boolean = false;
  @State shareCardGenerating: boolean = false;
  @State showSummaryShareCard: boolean = false;
  private toastTimer: number = 0;

  aboutToAppear(): void { this.initData(); }

  aboutToDisappear(): void {
    if (this.toastTimer > 0) clearTimeout(this.toastTimer);
    if (this.viewMode === MODE_PDF) {
      try { this.pdfController.releaseDocument(); } catch (_) {}
    }
    if (this.viewMode === MODE_HTML) {
      try { this.webCtrl.stop(); } catch (_) {}
    }
  }

  async initData(): Promise<void> {
    await PreferencesUtil.init(getContext(this));
    const json = AppStorage.get<string>('selectedPaperJson');
    if (json) {
      this.paper = JSON.parse(json) as Paper;
      this.isFavorite = PreferencesUtil.getFavoriteIds().includes(this.paper.id);
      this.readingProgress = await PreferencesUtil.getReadingProgress(this.paper.id);
    }
    try { this.llmInited = await localChatModel.init(); } catch (_) { this.llmInited = false; }
    this.loadRelatedPapers();
  }

  async loadRelatedPapers(): Promise<void> {
    if (!this.paper) return;
    this.relatedLoading = true;
    // Extract keywords from title
    const stopWords = ['a','an','the','of','for','in','on','to','and','with','by','from','is','are','that','this','via','using'];
    const words = this.paper.title.split(/[\s:,\-–]+/).filter(w => w.length > 3 && !stopWords.includes(w.toLowerCase()));
    const keywords = words.slice(0, 4).join(' ');
    if (!keywords) { this.relatedLoading = false; return; }
    try {
      const results = await ArxivService.searchPapers(`all:${keywords}`, 0, 6, false, 'relevance');
      this.relatedPapers = results.filter(p => p.id !== this.paper!.id).slice(0, 5);
    } catch (_) {}
    this.relatedLoading = false;
  }

  onBackPress(): boolean {
    if (this.showSummary) { this.showSummary = false; return true; }
    if (this.showColors) { this.showColors = false; return true; }
    if (this.showSearch) { this.closeSearch(); return true; }
    if (this.showJump) { this.showJump = false; return true; }
    if (this.activeTool >= 0) { this.stopAnnotation(); return true; }
    if (this.viewMode === MODE_PDF) { this.closePdf(); return true; }
    if (this.viewMode === MODE_HTML) { this.viewMode = MODE_ABSTRACT; return true; }
    return false;
  }

  async onWebScroll(p: number): Promise<void> {
    if (p <= 0) return; // ignore initial 0
    if (p > this.webScroll) this.webScroll = p;
    const o = Math.max(this.readingProgress, this.webScroll);
    if (o > this.readingProgress && this.paper) {
      this.readingProgress = Math.min(o, 100);
      await PreferencesUtil.saveReadingProgress(this.paper.id, this.readingProgress);
    }
  }

  async onPdfPageChanged(): Promise<void> {
    if (!this.paper || this.pageCount <= 0) return;
    const pdfProgress = Math.round(this.currentPage / this.pageCount * 100);
    if (pdfProgress > this.readingProgress) {
      this.readingProgress = pdfProgress;
      await PreferencesUtil.saveReadingProgress(this.paper.id, pdfProgress);
    }
    // Save PDF page bookmark
    await PreferencesUtil.savePdfPage(this.paper.id, this.currentPage);
  }

  toggleFav(): void {
    if (!this.paper) return;
    if (this.isFavorite) PreferencesUtil.removeFavorite(this.paper.id);
    else PreferencesUtil.addFavorite(this.paper);
    this.isFavorite = !this.isFavorite;
  }

  copyLink(): void {
    if (!this.paper) return;
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.paper.id);
    const board = pasteboard.getSystemPasteboard();
    board.setData(data);
    this.showToast('链接已复制');
  }

  async sharePaperText(): Promise<void> {
    if (!this.paper) return;
    const text = `${this.paper.title}\n\n${this.authors()}\n\n${this.paper.summary.substring(0, 200)}...\n\n${this.paper.id}`;
    try {
      const record: systemShare.SharedRecord = {
        utd: 'general.plain-text',
        content: text,
        title: this.paper.title,
        description: this.authors()
      };
      const data = new systemShare.SharedData(record);
      const controller = new systemShare.ShareController(data);
      const ctx = getContext(this) as common.UIAbilityContext;
      await controller.show(ctx, {
        previewMode: systemShare.SharePreviewMode.DETAIL,
        selectionMode: systemShare.SelectionMode.SINGLE
      });
    } catch (_) {
      const clipData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(clipData);
      this.showToast('分享内容已复制到剪贴板');
    }
  }

  async shareCardImage(): Promise<void> {
    if (!this.paper) return;
    this.showShareCard = true;
    this.shareCardGenerating = true;
    // Wait for card to render
    setTimeout(async () => {
      try {
        const pixelMap = await componentSnapshot.get('shareCardComp', { scale: 2, waitUntilRenderFinished: true });
        const packer = image.createImagePacker();
        const fp = getContext(this).filesDir + '/share_card.png';
        const file = fileIo.openSync(fp, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        await packer.packToFile(pixelMap, file.fd, { format: 'image/png', quality: 100 });
        fileIo.closeSync(file.fd);
        packer.release();
        pixelMap.release();

        const uri = fileUri.getUriFromPath(fp);
        const record: systemShare.SharedRecord = {
          utd: 'general.image',
          uri: uri,
          title: this.paper!.title,
          description: this.authors()
        };
        const shareData = new systemShare.SharedData(record);
        const controller = new systemShare.ShareController(shareData);
        const ctx = getContext(this) as common.UIAbilityContext;
        this.showShareCard = false;
        this.shareCardGenerating = false;
        await controller.show(ctx, {
          previewMode: systemShare.SharePreviewMode.DEFAULT,
          selectionMode: systemShare.SelectionMode.SINGLE
        });
      } catch (_) {
        this.showShareCard = false;
        this.shareCardGenerating = false;
        this.showToast('卡片生成失败，已改为文字分享');
        this.sharePaperText();
      }
    }, 300);
  }

  async shareSummaryImage(): Promise<void> {
    if (!this.paper || this.summaryText.length === 0) return;
    this.showSummaryShareCard = true;
    setTimeout(async () => {
      try {
        const pixelMap = await componentSnapshot.get('summaryShareComp', { scale: 2, waitUntilRenderFinished: true });
        const packer = image.createImagePacker();
        const fp = getContext(this).filesDir + '/share_summary.png';
        const file = fileIo.openSync(fp, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        await packer.packToFile(pixelMap, file.fd, { format: 'image/png', quality: 100 });
        fileIo.closeSync(file.fd);
        packer.release();
        pixelMap.release();
        const uri = fileUri.getUriFromPath(fp);
        const record: systemShare.SharedRecord = {
          utd: 'general.image',
          uri: uri,
          title: `AI 解读: ${this.paper!.title}`,
          description: 'arXplore AI 深度解读'
        };
        const shareData = new systemShare.SharedData(record);
        const controller = new systemShare.ShareController(shareData);
        const ctx = getContext(this) as common.UIAbilityContext;
        this.showSummaryShareCard = false;
        await controller.show(ctx, {
          previewMode: systemShare.SharePreviewMode.DEFAULT,
          selectionMode: systemShare.SelectionMode.SINGLE
        });
      } catch (_) {
        this.showSummaryShareCard = false;
        this.showToast('总结图片生成失败');
      }
    }, 300);
  }

  showToast(msg: string): void {
    this.toastMsg = msg;
    if (this.toastTimer > 0) clearTimeout(this.toastTimer);
    this.toastTimer = setTimeout(() => { this.toastMsg = ''; this.toastTimer = 0; }, 1500);
  }

  authors(): string {
    return this.paper ? this.paper.authors.map(a => a.name).join(', ') : '';
  }

  affiliations(): string {
    if (!this.paper) return '';
    const a: string[] = [];
    for (const au of this.paper.authors) {
      if (au.affiliation && !a.includes(au.affiliation)) a.push(au.affiliation);
    }
    return a.join(' · ');
  }

  fmtDate(d: string): string { return d ? d.substring(0, 10) : ''; }

  paperId(): string {
    if (!this.paper) return '';
    const i = this.paper.id.indexOf('/abs/');
    return i >= 0 ? this.paper.id.substring(i + 5) : '';
  }

  pdfUrl(): string { return (this.paper?.pdfUrl || '').replace('http://', 'https://'); }
  pdfPath(): string { return getContext(this).filesDir + '/' + this.paperId().replace(/[^a-zA-Z0-9.]/g, '_') + '.pdf'; }
  annoPath(): string { return getContext(this).filesDir + '/' + this.paperId().replace(/[^a-zA-Z0-9.]/g, '_') + '_anno.pdf'; }
  cached(): boolean { try { return fileIo.accessSync(this.pdfPath()); } catch (_) { return false; } }
  hasAnno(): boolean { try { return fileIo.accessSync(this.annoPath()); } catch (_) { return false; } }

  // ---- LLM ----
  buildPaperContext(): string {
    const p = this.paper!;
    return `标题：${p.title}\n作者：${this.authors()}\n机构：${this.affiliations()}\n分类：${p.categories.join(', ')}\n摘要：${p.summary}`;
  }

  async generateSummary(): Promise<void> {
    if (!this.paper) return;
    this.summaryLoading = true; this.summaryText = ''; this.showSummary = true;
    const ctx = this.buildPaperContext();

    if (this.llmInited) {
      // On-device: single prompt (limited capability)
      const prompt = `你是一位资深 AI 论文审稿人。请用中文对以下论文做结构化深度解读，严格按照以下格式输出，每个标题独占一行，内容紧跟标题下方：

【作者与机构】【问题定义】【研究背景】【业界现有方案】【论文方案】【主要成果】【不足与展望】【端侧部署启示】

${ctx}`;
      const question: localChatModel.QuestionInfo = { questionId: Date.now(), content: prompt };
      try {
        await localChatModel.chat(question, { isStream: true } as localChatModel.Config,
          (err, answer: localChatModel.Answer) => {
            if (err) { this.summaryText = '总结生成失败'; this.summaryLoading = false; return; }
            this.summaryText += answer.content;
            if (answer.isFinished) this.summaryLoading = false;
          });
      } catch (_) { this.summaryText = '总结生成失败，请稍后重试'; this.summaryLoading = false; }
    } else {
      // Cloud: split into 3 parallel requests, then merge
      const base = `你是一位资深 AI 论文审稿人，请用中文回答，严格按【标题】格式输出，每节 2-4 句话。\n\n${ctx}\n\n请只输出以下部分：\n`;
      const prompts: string[] = [
        base + '【作者与机构】简述第一作者和主要合作机构的背景\n【问题定义】论文要解决的核心问题\n【研究背景】该问题的学术和工业背景，为什么重要',
        base + '【业界现有方案】目前主流解决思路及其局限\n【论文方案】本文提出的方法/架构/算法核心思路\n【主要成果】关键实验结果、指标、与 SOTA 对比',
        base + '【不足与展望】论文局限性及未来改进方向\n【端侧部署启示】对移动端/边缘端大模型部署的参考价值（模型压缩、推理优化、量化、蒸馏等角度）',
      ];
      try {
        const results = await Promise.all(prompts.map(p => CloudLLMService.chat(p)));
        this.summaryText = results.join('\n\n');
      } catch (_) { this.summaryText = '云端 AI 请求失败，请检查网络'; }
      this.summaryLoading = false;
    }
  }

  async summarizeSelectedText(): Promise<void> {
    if (this.viewMode === MODE_HTML) {
      // Read cached selection (stored by selectionchange listener)
      try {
        const result = await this.webCtrl.runJavaScript('window._rp_sel||""');
        // runJavaScript returns JSON-encoded string, strip outer quotes
        let text = result || '';
        if (text.startsWith('"') && text.endsWith('"')) {
          text = text.substring(1, text.length - 1);
        }
        // Unescape common sequences
        text = text.replace(/\\n/g, '\n').replace(/\\"/g, '"').replace(/\\\\/g, '\\');
        if (text.length > 5) {
          this.selectedText = text;
          // Clear stored selection after reading
          this.webCtrl.runJavaScript('window._rp_sel=""');
          this.aiSummarize(text);
        } else {
          this.showToast('请先选中要总结的文字');
        }
      } catch (_) {
        this.showToast('获取选中文字失败');
      }
    } else if (this.viewMode === MODE_PDF) {
      // PDF doesn't expose selected text API — use clipboard
      try {
        const board = pasteboard.getSystemPasteboard();
        const clipData = await board.getData();
        const text = clipData.getPrimaryText();
        if (text && text.length > 5) {
          this.selectedText = text;
          this.aiSummarize(text);
          return;
        }
      } catch (_) {}
      this.showToast('请先选中文字并复制，再点击 AI');
    }
  }

  async aiSummarize(text: string): Promise<void> {
    this.summaryLoading = true;
    this.summaryText = '';
    this.showSummary = true;
    const prompt = `请用中文解读以下论文段落的含义，简明扼要地说明核心要点：\n\n${text}`;
    if (this.llmInited) {
      const question: localChatModel.QuestionInfo = { questionId: Date.now(), content: prompt };
      try {
        await localChatModel.chat(question, { isStream: true } as localChatModel.Config,
          (err, answer: localChatModel.Answer) => {
            if (err) { this.summaryText = '解读失败'; this.summaryLoading = false; return; }
            this.summaryText += answer.content;
            if (answer.isFinished) this.summaryLoading = false;
          });
      } catch (_) { this.summaryText = '解读失败，请稍后重试'; this.summaryLoading = false; }
    } else {
      try {
        this.summaryText = await CloudLLMService.chat(prompt);
      } catch (_) { this.summaryText = '云端 AI 请求失败，请检查网络'; }
      this.summaryLoading = false;
    }
  }

  // ---- Search ----
  openSearch(): void { this.showSearch = true; this.showColors = false; this.searchText = ''; this.matchCount = 0; this.matchIndex = 0; }
  closeSearch(): void { this.showSearch = false; try { this.pdfController.clearSearch(); } catch (_) {} }
  doSearch(): void {
    if (!this.searchText) return;
    try { this.pdfController.searchKey(this.searchText, (c: number) => { this.matchCount = c; this.matchIndex = c > 0 ? 1 : 0; }); } catch (_) {}
  }
  nextMatch(): void {
    if (this.matchCount <= 0) return;
    this.matchIndex = this.matchIndex >= this.matchCount ? 1 : this.matchIndex + 1;
    try { this.pdfController.setSearchIndex(this.matchIndex - 1); } catch (_) {}
  }
  prevMatch(): void {
    if (this.matchCount <= 0) return;
    this.matchIndex = this.matchIndex <= 1 ? this.matchCount : this.matchIndex - 1;
    try { this.pdfController.setSearchIndex(this.matchIndex - 1); } catch (_) {}
  }

  jumpTo(): void {
    const p = parseInt(this.jumpText);
    if (!isNaN(p) && p >= 1 && p <= this.pageCount) { try { this.pdfController.goToPage(p - 1); } catch (_) {} }
    this.showJump = false; this.jumpText = '';
  }

  // ---- Annotation ----
  annoEnum(t: number): pdfViewManager.SupportedAnnotationType {
    if (t === 1) return pdfViewManager.SupportedAnnotationType.UNDERLINE;
    if (t === 2) return pdfViewManager.SupportedAnnotationType.STRIKETHROUGH;
    return pdfViewManager.SupportedAnnotationType.HIGHLIGHT;
  }
  tapTool(t: number): void {
    if (this.activeTool === t) { this.stopAnnotation(); return; }
    this.activeTool = t; this.showColors = false;
    try { this.pdfController.enableAnnotation(this.annoEnum(t), ANNO_COLORS[this.colorIdx]); } catch (_) {}
  }
  stopAnnotation(): void { this.activeTool = -1; this.showColors = false; try { this.pdfController.disableAnnotation(); } catch (_) {} }
  pickColor(i: number): void {
    this.colorIdx = i; this.showColors = false;
    if (this.activeTool >= 0) { try { this.pdfController.enableAnnotation(this.annoEnum(this.activeTool), ANNO_COLORS[i]); } catch (_) {} }
  }

  async save(): Promise<void> {
    try {
      await this.pdfController.saveDocument(this.annoPath());
      this.unsaved = false;
      this.showToast('标注已保存');
    } catch (_) {
      this.showToast('保存失败');
    }
  }

  async closePdf(): Promise<void> {
    if (this.activeTool >= 0) this.stopAnnotation();
    if (this.unsaved) {
      try { await this.pdfController.saveDocument(this.annoPath()); } catch (_) {}
    }
    try { this.pdfController.releaseDocument(); } catch (_) {}
    this.viewMode = MODE_ABSTRACT;
  }

  deleteCachedPdf(): void {
    try { fileIo.unlinkSync(this.pdfPath()); } catch (_) {}
    try { fileIo.unlinkSync(this.annoPath()); } catch (_) {}
  }

  async openPdf(): Promise<void> {
    if (!this.paper) return;
    this.viewMode = MODE_PDF; this.pdfLoading = true; this.pdfError = ''; this.pdfDownloadProgress = 0;
    this.showSearch = false; this.showJump = false; this.showColors = false; this.activeTool = -1; this.unsaved = false;
    const fp = this.pdfPath();
    if (!this.cached()) {
      const ok = await this.downloadPdf(fp);
      if (!ok) return;
    }
    // Verify file size — arXiv may return HTML error pages
    try {
      const stat = fileIo.statSync(fp);
      if (stat.size < 1024) {
        this.deleteCachedPdf();
        this.pdfError = 'PDF 文件异常，可能遇到 arXiv 限流，请稍后重试';
        this.pdfLoading = false;
        return;
      }
    } catch (_) {}

    try { this.pdfController.registerPageChangedListener((i: number) => { this.currentPage = i + 1; this.onPdfPageChanged(); }); } catch (_) {}
    try { this.pdfController.registerPageCountChangedListener((c: number) => { this.pageCount = c; }); } catch (_) {}
    try { this.pdfController.registerAnnotationChangedListener((_: pdfViewManager.AnnotationChangedParam) => { this.unsaved = true; }); } catch (_) {}
    const lp = this.hasAnno() ? this.annoPath() : fp;
    try {
      await this.pdfController.loadDocument(lp);
      this.pageCount = this.pdfController.getPageCount();
      this.currentPage = this.pdfController.getPageIndex() + 1;
      if (this.pageCount === 0) {
        // Document loaded but 0 pages — corrupt file
        this.deleteCachedPdf();
        try { this.pdfController.releaseDocument(); } catch (_) {}
        this.pdfError = 'PDF 解析失败，缓存已清除，请重试';
        this.pdfLoading = false;
        return;
      }
      // Restore saved page bookmark
      const savedPage = await PreferencesUtil.getPdfPage(this.paper!.id);
      if (savedPage > 1 && savedPage <= this.pageCount) {
        try { this.pdfController.goToPage(savedPage - 1); } catch (_) {}
        this.currentPage = savedPage;
      }
      this.pdfLoading = false;
    } catch (_) {
      this.deleteCachedPdf();
      this.pdfError = 'PDF 加载失败，缓存已清除，请重试';
      this.pdfLoading = false;
    }
  }

  async downloadPdf(fp: string): Promise<boolean> {
    const url = this.pdfUrl();
    if (!url) { this.pdfError = 'PDF 链接不可用'; this.pdfLoading = false; return false; }
    const req = http.createHttp();
    req.on('dataReceiveProgress', (data) => {
      if (data.totalSize > 0) { this.pdfDownloadProgress = Math.round(data.receiveSize / data.totalSize * 100); }
    });
    try {
      const r = await req.request(url, {
        method: http.RequestMethod.GET,
        readTimeout: 120000,
        connectTimeout: 60000,
        usingProtocol: http.HttpProtocol.HTTP1_1,
        header: { 'User-Agent': 'Mozilla/5.0 (HarmonyOS) ReadingPapers/1.0', 'Accept': 'application/pdf' },
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      if (r.responseCode === 200) {
        const buf = r.result as ArrayBuffer;
        if (buf.byteLength < 1024) {
          this.pdfError = 'arXiv 返回异常，请稍后重试';
          this.pdfLoading = false;
          return false;
        }
        const f = fileIo.openSync(fp, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(f.fd, buf);
        fileIo.closeSync(f.fd);
        return true;
      } else {
        this.pdfError = `HTTP ${r.responseCode}`;
        this.pdfLoading = false;
        return false;
      }
    } catch (_) {
      this.pdfError = '下载失败，请检查网络';
      this.pdfLoading = false;
      return false;
    } finally {
      req.destroy();
    }
  }

  openHtml(): void {
    const pid = this.paperId(); if (!pid) return;
    this.webUrl = `https://arxiv.org/html/${pid}`; this.webProgress = 0; this.webScroll = 0; this.viewMode = MODE_HTML;
  }

  // ================================================================
  build() {
    Stack() {
      Column() {
        if (this.paper === null) {
          Column() { LoadingProgress().width(32).height(32).color('#007AFF') }
            .width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor('#FFFFFF')
        } else if (this.viewMode === MODE_PDF) {
          this.PdfReaderView()
        } else if (this.viewMode === MODE_HTML) {
          this.HtmlReaderView()
        } else {
          this.AbstractView()
        }
      }
      .width('100%').height('100%')

      if (this.showSummary) { this.SummarySheet() }

      // Share card (rendered offscreen for snapshot)
      if (this.showShareCard && this.paper) { this.ShareCardOverlay() }
      if (this.showSummaryShareCard && this.paper) { this.SummaryShareOverlay() }

      // Toast
      if (this.toastMsg) {
        Column() {
          Blank()
          Text(this.toastMsg)
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor('#1D1D1FCC')
            .borderRadius(20)
            .padding({ left: 20, right: 20, top: 10, bottom: 10 })
            .margin({ bottom: 120 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.None)
        .transition(TransitionEffect.OPACITY.animation({ duration: 300 }))
      }
    }
    .width('100%').height('100%')
  }

  pageTransition() {
    PageTransitionEnter({ duration: 250 }).slide(SlideEffect.Right)
    PageTransitionExit({ duration: 200 }).opacity(0.8)
  }

  // ================================================================
  //  Abstract — 沉浸式纯白阅读，像 Apple Books
  // ================================================================
  @Builder
  AbstractView() {
    Column() {
      // 导航栏 — 纯白，与内容无缝衔接
      Row() {
        Row() {
          Text('\u2039')
            .fontSize(34)
            .fontColor('#007AFF')
            .height(44)
            .textAlign(TextAlign.Center)
        }
        .width(56).height(44).justifyContent(FlexAlign.Center)
        .onClick(() => { router.back(); })

        Blank()

        Text('AI')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#007AFF')
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(14)
          .border({ width: 1, color: '#007AFF', style: BorderStyle.Solid })
          .margin({ right: 16 })
          .onClick(() => { this.generateSummary(); })

        Text('↗')
          .fontSize(20)
          .fontColor('#007AFF')
          .margin({ right: 16 })
          .bindMenu([
            { value: '分享卡片图', action: () => { this.shareCardImage(); } },
            { value: '分享文字', action: () => { this.sharePaperText(); } }
          ])

        Text(this.isFavorite ? '★' : '☆')
          .fontSize(22)
          .fontColor(this.isFavorite ? '#F53F3F' : '#C9CDD4')
          .onClick(() => { this.toggleFav(); })
      }
      .width('100%')
      .height(44)
      .padding({ left: 0, right: 20 })
      .alignItems(VerticalAlign.Center)

      // 内容 — 纯白连续排版
      Scroll(this.scroller) {
        Column() {
          // 分类标签
          Row({ space: 6 }) {
            ForEach(this.paper!.categories.slice(0, 3), (cat: string) => {
              Text(cat)
                .fontSize(11)
                .fontColor('#007AFF')
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .borderRadius(10)
                .border({ width: 0.5, color: '#007AFF66', style: BorderStyle.Solid })
            }, (cat: string) => cat)

            Blank()

            Text(`${this.fmtDate(this.paper!.published)}  ·  ~${Math.max(1, Math.ceil(this.paper!.summary.split(' ').length / 40))} min`)
              .fontSize(12)
              .fontColor('#AEAEB2')
          }
          .width('100%')
          .margin({ top: 4 })

          // 标题
          Text(this.paper!.title)
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#000000')
            .width('100%')
            .lineHeight(32)
            .margin({ top: 20 })

          // 作者
          Text(this.authors())
            .fontSize(14)
            .fontColor('#86868B')
            .width('100%')
            .lineHeight(21)
            .margin({ top: 16 })

          // 机构
          if (this.affiliations()) {
            Text(this.affiliations())
              .fontSize(12)
              .fontColor('#AEAEB2')
              .width('100%')
              .lineHeight(18)
              .margin({ top: 4 })
          }

          // 阅读进度条
          if (this.readingProgress > 0) {
            Row() {
              Progress({ value: this.readingProgress, total: 100 })
                .layoutWeight(1)
                .height(3)
                .color('#007AFF')
                .backgroundColor('#F2F2F7')
                .borderRadius(1.5)

              Text(`${this.readingProgress}%`)
                .fontSize(11)
                .fontColor('#AEAEB2')
                .margin({ left: 8 })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ top: 20 })
          }

          // arXiv ID + 操作
          Row({ space: 16 }) {
            Text(`arXiv: ${this.paperId()}`)
              .fontSize(12)
              .fontColor('#AEAEB2')

            Blank()

            Text('复制链接')
              .fontSize(12)
              .fontColor('#007AFF')
              .onClick(() => { this.copyLink(); })
          }
          .width('100%')
          .margin({ top: 16 })

          // 分隔线
          Divider()
            .color('#E5E5EA')
            .margin({ top: 20, bottom: 24 })

          // 摘要标签
          Text('Abstract')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor('#AEAEB2')
            .letterSpacing(1.5)
            .width('100%')
            .margin({ bottom: 12 })

          // 正文
          Text(this.paper!.summary)
            .fontSize(16)
            .fontColor('#1D1D1F')
            .lineHeight(26)
            .width('100%')

          // Related Papers
          if (this.relatedPapers.length > 0) {
            Divider().color('#E5E5EA').margin({ top: 24, bottom: 20 })

            Text('RELATED')
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor('#AEAEB2')
              .letterSpacing(1.5)
              .width('100%')
              .margin({ bottom: 12 })

            ForEach(this.relatedPapers, (rp: Paper) => {
              Row() {
                Column({ space: 4 }) {
                  Text(rp.title)
                    .fontSize(14).fontWeight(FontWeight.Medium).fontColor('#1D1D1F')
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(rp.authors.slice(0, 3).map(a => a.name).join(', '))
                    .fontSize(11).fontColor('#86868B')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                }
                .layoutWeight(1)

                Text('\u203A')
                  .fontSize(22).fontColor('#AEAEB2').margin({ left: 8 })
              }
              .width('100%')
              .padding({ top: 10, bottom: 10 })
              .border({ width: { bottom: 0.33 }, color: '#E5E5EA', style: BorderStyle.Solid })
              .onClick(() => {
                AppStorage.setOrCreate('selectedPaperJson', JSON.stringify(rp));
                router.pushUrl({ url: 'pages/PaperDetail' });
              })
            }, (rp: Paper) => rp.id)
          } else if (this.relatedLoading) {
            Row({ space: 8 }) {
              LoadingProgress().width(16).height(16).color('#AEAEB2')
              Text('正在查找相关论文...').fontSize(12).fontColor('#AEAEB2')
            }
            .width('100%').margin({ top: 20 })
          }

          Row().height(24)
        }
        .padding({ left: 24, right: 24 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)

      // 底部操作区
      Column() {
        Divider().color('#E5E5EA')

        Button(this.cached() ? '阅读全文' : '阅读 PDF')
          .type(ButtonType.Normal)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .backgroundColor('#007AFF')
          .borderRadius(12)
          .width('100%')
          .height(48)
          .margin({ top: 12 })
          .onClick(() => { this.openPdf(); })

        Row({ space: 12 }) {
          Button('HTML 版本')
            .type(ButtonType.Normal)
            .fontSize(14)
            .fontColor('#007AFF')
            .backgroundColor('#F2F2F7')
            .borderRadius(10)
            .layoutWeight(1)
            .height(42)
            .onClick(() => { this.openHtml(); })

          Button(this.cached() ? '已缓存' : '仅下载')
            .type(ButtonType.Normal)
            .fontSize(14)
            .fontColor(this.cached() ? '#34C759' : '#4E5969')
            .backgroundColor('#F2F2F7')
            .borderRadius(10)
            .layoutWeight(1)
            .height(42)
            .onClick(() => { if (!this.cached()) this.openPdf(); })
        }
        .width('100%')
        .margin({ top: 8 })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 0, bottom: 34 })
      .backgroundColor('#FFFFFF')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }

  // ================================================================
  //  AI Summary Sheet — Premium Design
  // ================================================================

  parseSections(): Array<[string, string, string, string]> {
    const sections: Array<[string, string, string, string]> = [];
    const iconMap: Record<string, [string, string]> = {
      '作者与机构': ['🏛', '#5856D6'],
      '问题定义': ['🎯', '#E17055'],
      '研究背景': ['📚', '#0984E3'],
      '业界现有方案': ['🔍', '#00B894'],
      '论文方案': ['💡', '#F39C12'],
      '主要成果': ['📊', '#E84393'],
      '不足与展望': ['⚠', '#636E72'],
      '端侧部署启示': ['📱', '#5856D6'],
    };
    const regex = /【([^】]+)】/g;
    const text = this.summaryText;
    const matches: Array<[number, string]> = [];
    let m: RegExpExecArray | null = regex.exec(text);
    while (m !== null) {
      matches.push([m.index, m[1]]);
      m = regex.exec(text);
    }
    for (let i = 0; i < matches.length; i++) {
      const title = matches[i][1];
      const start = matches[i][0] + title.length + 2;
      const end = i + 1 < matches.length ? matches[i + 1][0] : text.length;
      const content = text.substring(start, end).trim();
      const pair = iconMap[title];
      const icon = pair ? pair[0] : '•';
      const color = pair ? pair[1] : '#007AFF';
      sections.push([title, content, icon, color]);
    }
    return sections;
  }

  @Builder
  SummarySheet() {
    Column() {
      Blank()

      Column() {
        // Drag handle
        Column()
          .width(36).height(4).borderRadius(2).backgroundColor('#D1D1D6')
          .margin({ top: 10, bottom: 12 })

        // Header
        Row() {
          Row({ space: 6 }) {
            Text('✦')
              .fontSize(16)
              .fontColor('#007AFF')
            Text('AI 深度解读')
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1D1D1F')
          }

          Blank()

          if (this.llmInited) {
            Text('端侧')
              .fontSize(11)
              .fontColor('#34C759')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4)
              .backgroundColor('#34C75915')
          } else {
            Text('云侧')
              .fontSize(11)
              .fontColor('#007AFF')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4)
              .backgroundColor('#007AFF15')
          }

          if (!this.summaryLoading && this.summaryText.length > 0) {
            Text('↗')
              .fontSize(18)
              .fontColor('#007AFF')
              .margin({ left: 12 })
              .onClick(() => { this.shareSummaryImage(); })
          }

          Text('✕')
            .fontSize(18)
            .fontColor('#86868B')
            .fontWeight(FontWeight.Medium)
            .margin({ left: 12 })
            .onClick(() => { this.showSummary = false; })
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 12 })

        // Thin gradient divider
        Row()
          .width('100%')
          .height(2)
          .linearGradient({
            direction: GradientDirection.Right,
            colors: [['#007AFF', 0], ['#5856D6', 0.5], ['#E84393', 1]]
          })

        // Content area
        Scroll() {
          Column() {
            if (this.summaryLoading && this.summaryText.length === 0) {
              // Loading state — skeleton-like
              Column({ space: 16 }) {
                Row({ space: 10 }) {
                  LoadingProgress().width(20).height(20).color('#007AFF')
                  Text('正在深度分析论文...')
                    .fontSize(15)
                    .fontColor('#86868B')
                }

                // Shimmer hint
                ForEach(['作者与机构', '问题定义', '研究背景', '论文方案'], (title: string) => {
                  Row({ space: 8 }) {
                    Column()
                      .width(4)
                      .height(16)
                      .borderRadius(2)
                      .backgroundColor('#E5E5EA')
                    Text(title)
                      .fontSize(13)
                      .fontColor('#C7C7CC')
                  }
                })
              }
              .width('100%')
              .padding({ top: 24, left: 20, right: 20 })
              .alignItems(HorizontalAlign.Start)
            } else {
              // Parsed sections
              Column({ space: 2 }) {
                ForEach(this.parseSections(), (item: [string, string, string, string]) => {
                  Column() {
                    // Section header
                    Row({ space: 8 }) {
                      Text(item[2])
                        .fontSize(15)
                      Text(item[0])
                        .fontSize(15)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(item[3])
                    }
                    .margin({ bottom: 6 })

                    // Section content
                    Text(item[1])
                      .fontSize(14)
                      .fontColor('#3C3C43')
                      .lineHeight(22)
                      .width('100%')
                  }
                  .width('100%')
                  .padding(14)
                  .backgroundColor('#F8F9FA')
                  .borderRadius(10)
                  .border({ width: { left: 3 }, color: item[3] })
                })

                // Fallback: raw text when sections can't be parsed
                if (this.parseSections().length === 0 && this.summaryText.length > 0) {
                  Text(this.summaryText)
                    .fontSize(14)
                    .fontColor('#3C3C43')
                    .lineHeight(22)
                    .width('100%')
                    .padding(14)
                }

                if (this.summaryLoading) {
                  Row({ space: 6 }) {
                    LoadingProgress().width(14).height(14).color('#007AFF')
                    Text('生成中...')
                      .fontSize(13)
                      .fontColor('#86868B')
                  }
                  .margin({ top: 4 })
                  .justifyContent(FlexAlign.Center)
                  .width('100%')
                }
              }
              .padding({ top: 16, left: 16, right: 16 })
            }

            // Bottom: paper title reference
            if (this.paper && !this.summaryLoading) {
              Column() {
                Row()
                  .width(40)
                  .height(1)
                  .backgroundColor('#E5E5EA')
                  .margin({ top: 16, bottom: 10 })

                Text(this.paper!.title)
                  .fontSize(12)
                  .fontColor('#AEAEB2')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ left: 16, right: 16 })
              }
            }

            Row().height(28)
          }
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('75%')
      .backgroundColor('#FFFFFF')
      .borderRadius({ topLeft: 16, topRight: 16 })
      .shadow({ radius: 24, color: '#33000000', offsetX: 0, offsetY: -4 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#00000040')
    .onClick(() => { this.showSummary = false; })
  }

  // ================================================================
  //  PDF Reader
  // ================================================================
  @Builder
  PdfReaderView() {
    if (this.pdfLoading) {
      Column({ space: 12 }) {
        LoadingProgress().width(28).height(28).color('#007AFF')
        if (this.pdfDownloadProgress > 0 && this.pdfDownloadProgress < 100) {
          Text(`下载中 ${this.pdfDownloadProgress}%`).fontSize(15).fontColor('#86868B')
          Progress({ value: this.pdfDownloadProgress, total: 100 })
            .width('60%').height(3).color('#007AFF').backgroundColor('#F2F2F7').borderRadius(1.5)
        } else {
          Text('加载中...').fontSize(15).fontColor('#86868B')
        }
      }
      .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).backgroundColor('#FFFFFF')
    } else if (this.pdfError) {
      Column({ space: 16 }) {
        Text(this.pdfError).fontSize(15).fontColor('#86868B').textAlign(TextAlign.Center).padding({ left: 32, right: 32 })
        Text('重试').fontSize(16).fontColor('#FFFFFF').fontWeight(FontWeight.Medium)
          .backgroundColor('#007AFF').borderRadius(20)
          .padding({ left: 24, right: 24, top: 10, bottom: 10 })
          .onClick(() => { this.openPdf(); })
        Text('返回').fontSize(15).fontColor('#007AFF').margin({ top: 4 })
          .onClick(() => { this.viewMode = MODE_ABSTRACT; })
      }
      .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).backgroundColor('#FFFFFF')
    } else {
      // Nav
      Row() {
        Row() {
          Text('\u2039')
            .fontSize(34).fontColor('#007AFF').height(44).textAlign(TextAlign.Center)
        }
        .width(56).height(44).justifyContent(FlexAlign.Center)
        .onClick(() => { this.closePdf(); })

        Text(this.paper!.title)
          .fontSize(13).fontColor('#1D1D1F')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1).textAlign(TextAlign.Center)

        Text('搜索').fontSize(15).fontColor('#007AFF')
          .padding({ left: 12, right: 4 })
          .onClick(() => { this.openSearch(); })
      }
      .width('100%').height(44).padding({ left: 0, right: 16 })
      .alignItems(VerticalAlign.Center).backgroundColor('#FFFFFF')
      .border({ width: { bottom: 0.33 }, color: '#3C3C434D', style: BorderStyle.Solid })

      // Search
      if (this.showSearch) {
        Row({ space: 8 }) {
          TextInput({ placeholder: '搜索', text: this.searchText })
            .layoutWeight(1).height(36).fontSize(15)
            .backgroundColor('#7878801F').borderRadius(10)
            .padding({ left: 12, right: 12 })
            .onChange((v: string) => { this.searchText = v; })
            .onSubmit(() => { this.doSearch(); })

          if (this.matchCount > 0) {
            Text(`${this.matchIndex}/${this.matchCount}`)
              .fontSize(12).fontColor('#86868B').width(44).textAlign(TextAlign.Center)
            Text('\u2039').fontSize(22).fontColor('#007AFF').padding(4)
              .onClick(() => { this.prevMatch(); })
            Text('\u203A').fontSize(22).fontColor('#007AFF').padding(4)
              .onClick(() => { this.nextMatch(); })
          }

          Text('完成').fontSize(15).fontColor('#007AFF')
            .onClick(() => { this.closeSearch(); })
        }
        .width('100%').padding({ left: 12, right: 12, top: 6, bottom: 8 })
        .backgroundColor('#FFFFFF')
        .border({ width: { bottom: 0.33 }, color: '#3C3C434D', style: BorderStyle.Solid })
      }

      // PDF
      Stack() {
        PdfView({ controller: this.pdfController, pageFit: pdfService.PageFit.FIT_WIDTH, showScroll: true })
          .width('100%').height('100%')

        if (this.showJump) {
          Column() {
            Column({ space: 16 }) {
              Text('前往页面').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#000000')
              TextInput({ placeholder: `1 ~ ${this.pageCount}`, text: this.jumpText })
                .width('100%').height(44).fontSize(17).textAlign(TextAlign.Center).type(InputType.Number)
                .backgroundColor('#7878801F').borderRadius(12)
                .onChange((v: string) => { this.jumpText = v; }).onSubmit(() => { this.jumpTo(); })
              Divider().color('#E5E5EA')
              Row() {
                Text('取消').fontSize(17).fontColor('#007AFF').layoutWeight(1).textAlign(TextAlign.Center).height(44)
                  .onClick(() => { this.showJump = false; })
                Divider().vertical(true).height(20).color('#E5E5EA')
                Text('前往').fontSize(17).fontWeight(FontWeight.Medium).fontColor('#007AFF').layoutWeight(1).textAlign(TextAlign.Center).height(44)
                  .onClick(() => { this.jumpTo(); })
              }.width('100%')
            }
            .width(280).padding({ top: 24, left: 24, right: 24, bottom: 4 })
            .backgroundColor('#FFFFFF').borderRadius(14)
            .shadow({ radius: 20, color: '#33000000', offsetX: 0, offsetY: 4 })
          }
          .width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor('#00000040')
          .onClick(() => { this.showJump = false; })
        }
      }
      .width('100%').layoutWeight(1)

      // Color picker
      if (this.showColors) {
        Row({ space: 16 }) {
          ForEach([0, 1, 2, 3, 4], (i: number) => {
            Stack() {
              Circle().width(32).height(32).fill(ANNO_UI_COLORS[i])
                .stroke(this.colorIdx === i ? '#1D1D1F' : '#00000000').strokeWidth(2.5)
              if (this.colorIdx === i) { Text('✓').fontSize(13).fontColor('#FFFFFF').fontWeight(FontWeight.Bold) }
            }
            .onClick(() => { this.pickColor(i); })
          }, (i: number) => i.toString())
        }
        .width('100%').justifyContent(FlexAlign.Center).padding({ top: 10, bottom: 10 })
        .backgroundColor('#FFFFFF')
        .border({ width: { bottom: 0.33 }, color: '#3C3C434D', style: BorderStyle.Solid })
      }

      // Toolbar
      Row() {
        Row({ space: 2 }) {
          this.AnnoBtn('H', 0)
          this.AnnoBtn('U', 1)
          this.AnnoBtn('S', 2)
          Circle().width(18).height(18).fill(ANNO_UI_COLORS[this.colorIdx]).margin({ left: 8 })
            .onClick(() => { this.showColors = !this.showColors; })
          Text('AI').fontSize(11).fontWeight(FontWeight.Medium).fontColor('#007AFF')
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(10).border({ width: 1, color: '#007AFF', style: BorderStyle.Solid })
            .margin({ left: 8 })
            .onClick(() => { this.summarizeSelectedText(); })
        }.alignItems(VerticalAlign.Center)

        Blank()

        Row({ space: 2 }) {
          Text(`${this.currentPage}`).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#1D1D1F')
          Text(` / ${this.pageCount}`).fontSize(13).fontColor('#86868B')
        }.onClick(() => { this.jumpText = ''; this.showJump = true; })

        Blank()

        Row({ space: 6 }) {
          if (this.unsaved) {
            Text('保存').fontSize(13).fontColor('#007AFF').fontWeight(FontWeight.Medium)
              .onClick(() => { this.save(); })
          }
          Text(this.fitWidth ? '适页' : '适宽')
            .fontSize(12).fontColor('#007AFF')
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .border({ width: 0.5, color: '#007AFF', style: BorderStyle.Solid }).borderRadius(6)
            .onClick(() => { this.fitWidth = !this.fitWidth; try { this.pdfController.setPageFit(this.fitWidth ? pdfService.PageFit.FIT_WIDTH : pdfService.PageFit.FIT_PAGE); } catch (_) {} })
          Text(this.layoutSingle ? '双页' : '单页')
            .fontSize(12).fontColor('#007AFF')
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .border({ width: 0.5, color: '#007AFF', style: BorderStyle.Solid }).borderRadius(6)
            .onClick(() => { this.layoutSingle = !this.layoutSingle; try { this.pdfController.setPageLayout(this.layoutSingle ? pdfService.PageLayout.LAYOUT_SINGLE : pdfService.PageLayout.LAYOUT_DOUBLE); } catch (_) {} })
        }.alignItems(VerticalAlign.Center)
      }
      .width('100%').height(44).padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center).backgroundColor('#FFFFFF')
      .border({ width: { top: 0.33 }, color: '#3C3C434D', style: BorderStyle.Solid })

      Row().width('100%').height(24).backgroundColor('#FFFFFF')
    }
  }

  // ================================================================
  //  HTML Reader
  // ================================================================
  @Builder
  HtmlReaderView() {
    Row() {
      Row() {
        Text('\u2039').fontSize(34).fontColor('#007AFF').height(44).textAlign(TextAlign.Center)
      }
      .width(56).height(44).justifyContent(FlexAlign.Center)
      .onClick(() => { this.viewMode = MODE_ABSTRACT; })

      Text(this.paper!.title)
        .fontSize(13).fontColor('#1D1D1F')
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1).textAlign(TextAlign.Center)

      Text('AI')
        .fontSize(13).fontWeight(FontWeight.Medium).fontColor('#007AFF')
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .borderRadius(14)
        .border({ width: 1, color: '#007AFF', style: BorderStyle.Solid })
        .onClick(() => { this.summarizeSelectedText(); })
    }
    .width('100%').height(44).padding({ left: 0, right: 16 })
    .alignItems(VerticalAlign.Center).backgroundColor('#FFFFFF')
    .border({ width: { bottom: 0.33 }, color: '#3C3C434D', style: BorderStyle.Solid })

    if (this.webProgress > 0 && this.webProgress < 100) {
      Progress({ value: this.webProgress, total: 100 }).width('100%').height(2).color('#007AFF').backgroundColor('#F2F2F7')
    }
    Web({ src: this.webUrl, controller: this.webCtrl })
      .width('100%').layoutWeight(1).javaScriptAccess(true)
      .onProgressChange((e) => { if (e) this.webProgress = e.newProgress; })
      .onPageEnd(() => { try { this.webCtrl.runJavaScript(SCROLL_TRACK_JS); } catch (_) {} })
      .onConsole((e) => {
        if (e) { const m = e.message.getMessage(); if (m.startsWith('_RP_:')) { const p = parseInt(m.substring(5)); if (!isNaN(p)) this.onWebScroll(p); } }
        return false;
      })
  }

  // ================================================================
  //  Annotation Button
  // ================================================================
  @Builder
  AnnoBtn(label: string, tool: number) {
    Text(label)
      .fontSize(15).fontWeight(FontWeight.Bold)
      .fontColor(this.activeTool === tool ? '#FFFFFF' : '#1D1D1F')
      .backgroundColor(this.activeTool === tool ? ANNO_UI_COLORS[this.colorIdx] : '#00000000')
      .width(34).height(30).textAlign(TextAlign.Center).borderRadius(7)
      .border({ width: this.activeTool === tool ? 0 : 0.5, color: '#D1D1D6', style: BorderStyle.Solid })
      .decoration(
        tool === 1 ? { type: TextDecorationType.Underline, color: this.activeTool === 1 ? '#FFFFFF' : '#1D1D1F' } :
        tool === 2 ? { type: TextDecorationType.LineThrough, color: this.activeTool === 2 ? '#FFFFFF' : '#1D1D1F' } :
        { type: TextDecorationType.None }
      )
      .margin({ right: 4 })
      .onClick(() => { this.tapTool(tool); })
  }

  // ================================================================
  //  Share Card — 精美分享卡片
  // ================================================================
  @Builder
  ShareCardOverlay() {
    Column() {
      // Semi-transparent backdrop
      Column() {
        if (this.shareCardGenerating) {
          LoadingProgress().width(32).height(32).color('#FFFFFF')
          Text('正在生成分享卡片...').fontSize(14).fontColor('#FFFFFF').margin({ top: 8 })
        }
      }
      .width('100%').height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor('#00000066')

      // The actual card — positioned offscreen but still rendered for snapshot
      Column({ space: 0 }) {
        // Top gradient bar
        Row()
          .width('100%').height(6)
          .linearGradient({ direction: GradientDirection.Right, colors: [['#007AFF', 0], ['#00C6FF', 1]] })

        Column({ space: 14 }) {
          // App branding
          Row() {
            Text('arXplore')
              .fontSize(13).fontWeight(FontWeight.Bold).fontColor('#007AFF')
            Blank()
            Text('arxiv.org')
              .fontSize(11).fontColor('#AEAEB2')
          }
          .width('100%')

          // Title
          Text(this.paper!.title)
            .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1D1D1F')
            .lineHeight(26).width('100%')
            .maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis })

          // Authors
          Text(this.authors())
            .fontSize(12).fontColor('#86868B')
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          // Meta: categories + date
          Row({ space: 6 }) {
            ForEach(this.paper!.categories.slice(0, 3), (cat: string) => {
              Text(cat)
                .fontSize(10).fontColor('#007AFF')
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .borderRadius(10).backgroundColor('#EDF4FF')
            }, (cat: string) => cat)
            Blank()
            Text(this.fmtDate(this.paper!.published))
              .fontSize(11).fontColor('#AEAEB2')
          }
          .width('100%')

          // Divider
          Row().width('100%').height(1).backgroundColor('#F2F2F7')

          // Abstract excerpt
          Text(this.paper!.summary)
            .fontSize(13).fontColor('#4E5969')
            .lineHeight(21).maxLines(6)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          // Bottom: arXiv ID + QR hint
          Row().width('100%').height(1).backgroundColor('#F2F2F7').margin({ top: 4 })

          Row() {
            Column({ space: 2 }) {
              Text(this.paperId())
                .fontSize(11).fontColor('#AEAEB2')
              Text('来自 arXplore · 论文速读')
                .fontSize(10).fontColor('#C9CDD4')
            }
            Blank()
            // Stylized icon placeholder
            Column() {
              Text('aX')
                .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            }
            .width(44).height(44).borderRadius(10)
            .backgroundColor('#007AFF')
            .justifyContent(FlexAlign.Center)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 16 })
      }
      .width(360)
      .backgroundColor('#FFFFFF')
      .borderRadius(16)
      .shadow({ radius: 16, color: '#26000000', offsetX: 0, offsetY: 4 })
      .position({ x: -9999 })
      .id('shareCardComp')
    }
    .width('100%').height('100%')
  }

  // ================================================================
  //  AI Summary Share Card — 分享 AI 解读为图片
  // ================================================================
  @Builder
  SummaryShareOverlay() {
    Column() {
      // Backdrop
      Column() {
        LoadingProgress().width(32).height(32).color('#FFFFFF')
        Text('正在生成解读卡片...').fontSize(14).fontColor('#FFFFFF').margin({ top: 8 })
      }
      .width('100%').height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor('#00000066')

      // Offscreen card for snapshot
      Column({ space: 0 }) {
        // Top gradient
        Row()
          .width('100%').height(6)
          .linearGradient({ direction: GradientDirection.Right, colors: [['#007AFF', 0], ['#5856D6', 0.5], ['#E84393', 1]] })

        Column({ space: 12 }) {
          // Header: branding + badge
          Row() {
            Row({ space: 4 }) {
              Text('✦').fontSize(14).fontColor('#007AFF')
              Text('arXplore AI 深度解读').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#007AFF')
            }
            Blank()
            Text(this.llmInited ? '端侧推理' : '云侧推理')
              .fontSize(10).fontColor('#86868B')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4).backgroundColor('#F2F2F7')
          }
          .width('100%')

          // Paper title
          Text(this.paper!.title)
            .fontSize(15).fontWeight(FontWeight.Bold).fontColor('#1D1D1F')
            .lineHeight(22).width('100%')
            .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })

          // Authors
          Text(this.authors())
            .fontSize(11).fontColor('#86868B')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Row().width('100%').height(1).backgroundColor('#F2F2F7')

          // Sections
          ForEach(this.parseSections(), (item: [string, string, string, string]) => {
            Column() {
              Row({ space: 6 }) {
                Text(item[2]).fontSize(12)
                Text(item[0]).fontSize(12).fontWeight(FontWeight.Bold).fontColor(item[3])
              }
              .margin({ bottom: 4 })

              Text(item[1])
                .fontSize(11).fontColor('#3C3C43')
                .lineHeight(18).width('100%')
            }
            .width('100%')
            .padding(10)
            .backgroundColor('#F8F9FA')
            .borderRadius(8)
            .border({ width: { left: 2 }, color: item[3] })
          })

          // Fallback raw text
          if (this.parseSections().length === 0 && this.summaryText.length > 0) {
            Text(this.summaryText)
              .fontSize(11).fontColor('#3C3C43')
              .lineHeight(18).width('100%')
          }

          // Footer
          Row().width('100%').height(1).backgroundColor('#F2F2F7').margin({ top: 4 })

          Row() {
            Column({ space: 2 }) {
              Text(this.paperId()).fontSize(10).fontColor('#AEAEB2')
              Text('来自 arXplore · AI 深度解读').fontSize(9).fontColor('#C9CDD4')
            }
            Blank()
            Column() {
              Text('aX').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            }
            .width(36).height(36).borderRadius(8)
            .linearGradient({ direction: GradientDirection.Right, colors: [['#007AFF', 0], ['#5856D6', 1]] })
            .justifyContent(FlexAlign.Center)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      }
      .width(380)
      .backgroundColor('#FFFFFF')
      .borderRadius(16)
      .shadow({ radius: 16, color: '#26000000', offsetX: 0, offsetY: 4 })
      .position({ x: -9999 })
      .id('summaryShareComp')
    }
    .width('100%').height('100%')
  }
}
