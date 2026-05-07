using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Utils
{
    public static class JsonConverter
    {
        public static T LoadToVar<T>(JObject source, string key, T ifEmpty)
        {
            T result = default(T);
            try
            {
                result = source.ContainsKey(key) ? source[key].ToObject<T>() : ifEmpty;
            } catch(Exception ex)
            {
                MainWindow.Instance.Log.AddMessage(AccountApi.Origin.Other, ex.Message);
            }
            return result;
        }
    }
}
