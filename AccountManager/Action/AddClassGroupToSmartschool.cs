using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class AddClassGroupToSmartschool : IAction
    {
        public string Header => "Klas toevoegen aan Smartschool";

        public string Description => "Voeg deze klas toe aan Smartschool.";

        public bool CanBeApplied => true;

        public ObservableProperties.Prop<bool> InProgress { get; set; } = new ObservableProperties.Prop<bool>() { Value = false };

        public async Task Apply(LinkedGroup linkedGroup)
        {
            throw new NotImplementedException();
        }

        public AddClassGroupToSmartschool(WisaApi.ClassGroup group)
        {
            this.group = group;
        }

        WisaApi.ClassGroup group;
    }
}
