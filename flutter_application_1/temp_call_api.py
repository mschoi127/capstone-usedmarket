# -*- coding: utf-8 -*-
import asyncio, httpx, json

async def main():
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get('http://localhost:3001/products/price-stats', params={'keyword': '갤럭시 s25'})
        print(resp.status_code)
        print(json.dumps(resp.json(), ensure_ascii=False))

asyncio.run(main())
