using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class DoNotImportFromWisa : IAction
    {
        public string Header => "Klas Negeren";
        public string Description => "Een Wisa importregel toevoegen om deze groep te negeren. Doe dit als het nodig is dat de groep bestaat in WISA, " +
            "maar niet nodig is in Active Directory en Smartschool.";

        public bool CanBeApplied => true;

        public ObservableProperties.Prop<bool> InProgress { get; set; } = new ObservableProperties.Prop<bool>() { Value = false };

        public async Task Apply(LinkedGroup linkedGroup)
        {
            
        }

        public DoNotImportFromWisa(WisaApi.ClassGroup group)
        {
            this.group = group;
        }

        private WisaApi.ClassGroup group;
    }
}
