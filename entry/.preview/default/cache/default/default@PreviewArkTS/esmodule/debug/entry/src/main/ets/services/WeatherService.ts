import http from "@ohos:net.http";
const AMAP_KEY: string = ''; // 在这里粘贴你的高德 Web服务 Key
const DEFAULT_CITY_CODE: string = '330100'; // 默认杭州，换成你的城市编码
export interface WeatherProvider {
    getWeather(cityCode: string): Promise<string>;
}
/** 真实天气：调用高德天气 API */
export class AmapWeatherProvider implements WeatherProvider {
    async getWeather(cityCode: string): Promise<string> {
        const req: http.HttpRequest = http.createHttp();
        try {
            const url: string = `https://restapi.amap.com/v3/weather/weatherInfo?city=${cityCode}&key=${AMAP_KEY}&extensions=base`;
            const resp: http.HttpResponse = await req.request(url, {
                method: http.RequestMethod.GET,
                connectTimeout: 8000,
                readTimeout: 8000
            });
            if (resp.responseCode !== 200) {
                throw new Error(`weather HTTP ${resp.responseCode}`);
            }
            const raw: string = resp.result as string;
            const obj: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
            const lives = obj['lives'] as Array<Record<string, string>>;
            if (lives !== undefined && lives.length > 0) {
                return lives[0]['weather']; // 例如 "小雨" "多云" "晴"
            }
            throw new Error('weather empty result');
        }
        finally {
            req.destroy();
        }
    }
}
/** 离线兜底：固定返回小雨，方便演示"天气影响出行"的场景 */
export class MockWeatherProvider implements WeatherProvider {
    async getWeather(cityCode: string): Promise<string> {
        return '小雨';
    }
}
export class WeatherService {
    private static provider: WeatherProvider = AMAP_KEY.length > 0 ? new AmapWeatherProvider() : new MockWeatherProvider();
    static async getWeather(cityCode: string = DEFAULT_CITY_CODE): Promise<string> {
        try {
            return await WeatherService.provider.getWeather(cityCode);
        }
        catch (e) {
            console.error(`[WeatherService] failed, fallback to mock: ${e}`);
            const fallback: MockWeatherProvider = new MockWeatherProvider();
            return await fallback.getWeather(cityCode);
        }
    }
}
