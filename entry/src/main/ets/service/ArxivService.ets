import { http } from '@kit.NetworkKit';
import { Author, Paper } from '../model/DataModels';

const BASE_URL = 'https://export.arxiv.org/api/query';
const CACHE_TTL = 30 * 60 * 1000; // 30 minutes

interface CacheEntry {
  papers: Paper[];
  timestamp: number;
}

export class ArxivService {
  private static cache: Record<string, CacheEntry> = {};

  static async searchPapers(query: string, start: number = 0, maxResults: number = 20,
    forceRefresh: boolean = false, sortBy: string = 'submittedDate'): Promise<Paper[]> {

    // Cache only first page; return cached if fresh
    const cacheKey = `${query}__${sortBy}`;
    if (start === 0 && !forceRefresh) {
      const cached = ArxivService.cache[cacheKey];
      if (cached && Date.now() - cached.timestamp < CACHE_TTL) {
        return cached.papers;
      }
    }

    const encodedQuery = encodeURIComponent(query);
    const url =
      `${BASE_URL}?search_query=${encodedQuery}&start=${start}&max_results=${maxResults}&sortBy=${sortBy}&sortOrder=descending`;

    let lastError: Error | null = null;
    for (let attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await new Promise<void>((resolve) => { setTimeout(resolve, 2000 * attempt); });
      }
      const httpRequest = http.createHttp();
      try {
        const response = await httpRequest.request(url, {
          method: http.RequestMethod.GET,
          readTimeout: 60000,
          connectTimeout: 60000,
          usingProtocol: http.HttpProtocol.HTTP1_1,
          header: { 'User-Agent': 'Mozilla/5.0 (HarmonyOS) arXplore/1.0', 'Accept': 'application/xml' },
        });
        if (response.responseCode === 200) {
          const xmlStr = response.result as string;
          const papers = ArxivService.parseAtomFeed(xmlStr);
          if (start === 0 && papers.length > 0) {
            ArxivService.cache[cacheKey] = { papers, timestamp: Date.now() };
          }
          return papers;
        }
        if (response.responseCode >= 500) {
          lastError = new Error(`HTTP ${response.responseCode}`);
          continue; // retry on 5xx
        }
        return []; // 4xx: don't retry
      } catch (e) {
        lastError = e as Error;
      } finally {
        httpRequest.destroy();
      }
    }
    throw lastError || new Error('Network error');
  }

  static getCacheTime(query: string, sortBy: string = 'submittedDate'): number {
    const cached = ArxivService.cache[`${query}__${sortBy}`];
    return cached ? cached.timestamp : 0;
  }

  private static parseAtomFeed(xml: string): Paper[] {
    const papers: Paper[] = [];
    const entries = xml.split('<entry>');

    for (let i = 1; i < entries.length; i++) {
      const entry = entries[i];
      const endIdx = entry.indexOf('</entry>');
      const entryXml = endIdx >= 0 ? entry.substring(0, endIdx) : entry;

      try {
        const paper = ArxivService.parseEntry(entryXml);
        if (paper) {
          papers.push(paper);
        }
      } catch (e) {
        console.error('Parse entry error: ' + JSON.stringify(e));
      }
    }
    return papers;
  }

  private static parseEntry(entryXml: string): Paper | null {
    const id = ArxivService.extractTag(entryXml, 'id');
    if (!id) return null;

    const title = ArxivService.extractTag(entryXml, 'title').replace(/\s+/g, ' ').trim();
    const summary = ArxivService.extractTag(entryXml, 'summary').replace(/\s+/g, ' ').trim();
    const published = ArxivService.extractTag(entryXml, 'published');
    const updated = ArxivService.extractTag(entryXml, 'updated');

    const authors = ArxivService.parseAuthors(entryXml);
    const pdfUrl = ArxivService.extractLinkHref(entryXml, 'pdf');
    const htmlUrl = id.replace('/abs/', '/html/');
    const categories = ArxivService.parseCategories(entryXml);

    return {
      id, title, summary, authors, published, updated, pdfUrl, htmlUrl, categories,
    };
  }

  private static extractTag(xml: string, tag: string): string {
    const patterns: string[] = [`<${tag}>`, `<${tag} `];
    let startIdx = -1;
    for (const p of patterns) {
      startIdx = xml.indexOf(p);
      if (startIdx >= 0) break;
    }
    if (startIdx < 0) return '';

    const closeAngle = xml.indexOf('>', startIdx);
    if (closeAngle < 0) return '';

    const contentStart = closeAngle + 1;
    const endTag = `</${tag}>`;
    const endIdx = xml.indexOf(endTag, contentStart);
    if (endIdx < 0) return '';

    return xml.substring(contentStart, endIdx);
  }

  private static parseAuthors(xml: string): Author[] {
    const authors: Author[] = [];
    const parts = xml.split('<author>');

    for (let i = 1; i < parts.length; i++) {
      const part = parts[i];
      const endIdx = part.indexOf('</author>');
      const authorXml = endIdx >= 0 ? part.substring(0, endIdx) : part;

      const name = ArxivService.extractTag(authorXml, 'name').trim();
      let affiliation = '';

      const affIdx = authorXml.indexOf('affiliation');
      if (affIdx >= 0) {
        const closeAngle = authorXml.indexOf('>', affIdx);
        if (closeAngle >= 0) {
          const affEnd = authorXml.indexOf('</', closeAngle);
          if (affEnd >= 0) {
            affiliation = authorXml.substring(closeAngle + 1, affEnd).trim();
          }
        }
      }

      if (name) {
        authors.push({ name, affiliation });
      }
    }
    return authors;
  }

  private static extractLinkHref(xml: string, titleAttr: string): string {
    const pattern = `title="${titleAttr}"`;
    const idx = xml.indexOf(pattern);
    if (idx < 0) return '';

    const surroundStart = xml.lastIndexOf('<link', idx);
    if (surroundStart < 0) return '';

    const surroundEnd = xml.indexOf('/>', idx);
    if (surroundEnd < 0) return '';

    const linkTag = xml.substring(surroundStart, surroundEnd);
    const hrefIdx = linkTag.indexOf('href="');
    if (hrefIdx < 0) return '';

    const hrefStart = hrefIdx + 6;
    const hrefEnd = linkTag.indexOf('"', hrefStart);
    if (hrefEnd < 0) return '';

    return linkTag.substring(hrefStart, hrefEnd);
  }

  private static parseCategories(xml: string): string[] {
    const categories: string[] = [];
    let searchFrom = 0;

    while (true) {
      const idx = xml.indexOf('<category', searchFrom);
      if (idx < 0) break;

      const termIdx = xml.indexOf('term="', idx);
      if (termIdx < 0) break;

      const termStart = termIdx + 6;
      const termEnd = xml.indexOf('"', termStart);
      if (termEnd < 0) break;

      const term = xml.substring(termStart, termEnd);
      if (!categories.includes(term)) {
        categories.push(term);
      }
      searchFrom = termEnd + 1;
    }
    return categories;
  }
}
