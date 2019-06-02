using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class NoActionNeeded : IAction
    {
        public string Header => "Geen Actie Nodig";
        public string Description => "Deze groepen zijn in sync. Het is niet nodig om ze aan te passen.";

        public bool CanBeApplied => false;

        public ObservableProperties.Prop<bool> InProgress { get; set; } = new ObservableProperties.Prop<bool>() { Value = false };

        public async Task Apply(LinkedGroup linkedGroup)
        {
            
        }
    }
}
