using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Linked
{
    public class LinkedState : AbstractState
    {
        public Groups Groups = new Groups();
        public Accounts Accounts = new Accounts();

        public override void LoadConfig(JObject obj)
        {
            throw new NotImplementedException();
        }

        public override Task LoadContent()
        {
            throw new NotImplementedException();
        }

        public override void LoadLocalContent()
        {
            throw new NotImplementedException();
        }

        public override JObject SaveConfig()
        {
            throw new NotImplementedException();
        }

        public override void SaveContent()
        {
            throw new NotImplementedException();
        }
    }
}
