using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State
{
    public abstract class AbstractState : IStateSubject
    {
        private List<IStateObserver> observers = new List<IStateObserver>();

        public void AddObserver(IStateObserver observer)
        {
            if(!observers.Contains(observer))
            {
                observers.Add(observer);
            }
        }

        public void RemoveObserver(IStateObserver observer)
        {
            if (observers.Contains(observer))
            {
                observers.Remove(observer);
            }
        }

        public void UpdateObservers()
        {
            observers.ForEach(observer =>
            {
                observer.OnStateChanges();
            });
        }

        public abstract void LoadConfig(JObject obj);

        public abstract JObject SaveConfig();

        public abstract void SaveContent();

        public abstract Task LoadContent();
        public abstract void LoadLocalContent();
    }
}
