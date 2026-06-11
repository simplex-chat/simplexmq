// Override IDBValidKey to accept Uint8Array (supported in modern browsers)
interface IDBObjectStore {
  get(query: any): IDBRequest<any>
  getAll(query?: any, count?: number): IDBRequest<any[]>
  getAllKeys(query?: any, count?: number): IDBRequest<any[]>
  add(value: any, key?: any): IDBRequest<any>
  put(value: any, key?: any): IDBRequest<any>
  delete(query: any): IDBRequest<undefined>
}

interface IDBIndex {
  get(query: any): IDBRequest<any>
  getAll(query?: any, count?: number): IDBRequest<any[]>
  getAllKeys(query?: any, count?: number): IDBRequest<any[]>
}
