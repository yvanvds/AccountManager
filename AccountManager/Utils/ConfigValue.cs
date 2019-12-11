using AccountApi;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Utils
{
    public delegate void UpdateObserverFunc();
    public delegate void UpdateStateFunc(ConnectionState state);
    public class ConfigValue<T>
    {
        UpdateObserverFunc updateObservers;
        UpdateStateFunc updateState;
        T defaultValue;
        string key;

        public ConfigValue(string key, T defaultValue, UpdateObserverFunc updateObservers = null, UpdateStateFunc updateState = null)
        {
            this.updateObservers = updateObservers;
            this.updateState = updateState;
            this.key = key;
            this.defaultValue = defaultValue;
        }

        T value;
        public T Value
        {
            get => value;
            set
            {
                this.value = value;
                updateState?.Invoke(ConnectionState.Unknown);
                updateObservers();
            }
        }

        public void Load(JObject source)
        {
            value = Utils.JsonConverter.LoadToVar<T>(source, key, defaultValue);
        }

        public void Save(ref JObject target)
        {
            target[key] = value?.ToString();
        }
    }
}
