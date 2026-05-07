using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State
{
    interface IStateSubject
    {
        #region Subject Interface
        void AddObserver(IStateObserver observer);
        void RemoveObserver(IStateObserver observer);
        void UpdateObservers();
        #endregion

        #region State Interface
        void LoadConfig(JObject obj);
        JObject SaveConfig();

        Task LoadContent();
        void LoadLocalContent();

        void SaveContent();
        #endregion
    }
}
